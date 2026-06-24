import Foundation

/// Live `SummarizationService` backed by any OpenAI-compatible chat-completions
/// endpoint (Ollama's `/v1`, LM Studio, llama.cpp's server, OpenAI itself, …).
///
/// Behavioral parity with `MockSummarizationService`:
///  - `listModels` returns the model ids exposed by the server.
///  - `testConnection` returns on success and throws a typed `LLMError` otherwise.
///  - `summarize` yields the *accumulated* summary text (each value is the full
///    text produced so far), so a consumer can bind the latest value directly to
///    a `Text` view without having to concatenate deltas itself.
///
/// All failures are mapped to `LLMError` with a meaningful `LLMErrorKind`. The
/// service never traps: malformed URLs, dropped connections, auth rejections and
/// server errors all surface as recoverable thrown errors.
final class OpenAICompatibleLLM: SummarizationService {

    /// `baseURL` strings are assumed to already end in `/v1` (e.g.
    /// `http://localhost:11434/v1`). Heavy/throwing work happens inside the async
    /// methods, never here, so construction is cheap and total.
    init() {}

    // MARK: Tuning knobs

    /// Above this prompt size we switch to map-reduce instead of a single call.
    /// ~24k chars ≈ a long meeting transcript that would overflow small local
    /// context windows; chosen to match the contract's stated heuristic.
    private let mapReduceThreshold = 24_000

    /// Target size of each transcript chunk during map-reduce. Kept comfortably
    /// under the threshold so each map call stays within context.
    private let chunkSize = 12_000

    /// Marker that splits the static prompt scaffold from the transcript body so
    /// map-reduce only chunks the (large) transcript, never the instructions.
    private let transcriptToken = "{transcript}"

    /// A dedicated session: generous resource timeout for long streamed
    /// completions, modest request timeout so an unreachable host fails fast.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - SummarizationService

    /// `GET {baseURL}/models` → the list of available model ids.
    func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        let url = try endpoint(baseURL, path: "models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(&request, apiKey: apiKey)

        let (data, response) = try await perform(request)
        try validate(response, body: data)

        do {
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return decoded.data.map(\.id)
        } catch {
            throw LLMError(kind: .unknown,
                           message: "Couldn't parse the model list: \(error.localizedDescription)")
        }
    }

    /// Minimal one-token chat completion to confirm the model is reachable and
    /// actually exists. Returns on success; throws `.modelNotFound` for a missing
    /// model, or another typed `LLMError` for transport/auth/server problems.
    func testConnection(baseURL: String, apiKey: String?, model: String) async throws {
        let url = try endpoint(baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey)

        let payload = ChatRequest(
            model: model,
            messages: [.init(role: "user", content: "ping")],
            stream: false,
            maxTokens: 1,
            temperature: 0
        )
        request.httpBody = try encode(payload)

        let (data, response) = try await perform(request)
        try validate(response, body: data)
        // A 2xx with a parseable body (or even an empty one) means the model
        // answered — nothing more to assert.
    }

    /// Streams the summary text incrementally, applying map-reduce for very long
    /// prompts. Each yielded `String` is the full accumulated text so far.
    func summarize(prompt: String, baseURL: String, apiKey: String?, model: String)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if prompt.count > self.mapReduceThreshold {
                        try await self.summarizeMapReduce(
                            prompt: prompt, baseURL: baseURL, apiKey: apiKey,
                            model: model, continuation: continuation)
                    } else {
                        try await self.streamCompletion(
                            prompt: prompt, baseURL: baseURL, apiKey: apiKey,
                            model: model, continuation: continuation)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: self.mapError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Streaming primitive

    /// POSTs `chat/completions` with `stream: true`, parses the SSE body and
    /// yields the accumulated assistant text after each delta.
    private func streamCompletion(prompt: String, baseURL: String, apiKey: String?,
                                  model: String,
                                  continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let url = try endpoint(baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(&request, apiKey: apiKey)

        let payload = ChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            stream: true,
            maxTokens: nil,
            temperature: 0.2
        )
        request.httpBody = try encode(payload)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw mapError(error)
        }

        // Validate status before consuming the stream. On an error status the
        // server sends a JSON error body rather than SSE, so collect and map it.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            try validate(response, body: body)
            return
        }

        var accumulated = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }   // skip blanks / SSE comments

            let payloadText = String(trimmed.dropFirst("data:".count))
                .trimmingCharacters(in: .whitespaces)
            if payloadText.isEmpty { continue }
            if payloadText == "[DONE]" { break }

            guard let chunkData = payloadText.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatStreamChunk.self, from: chunkData)
            else { continue }   // tolerate a stray non-JSON keepalive line

            if let delta = chunk.choices.first?.delta?.content, !delta.isEmpty {
                accumulated += delta
                continuation.yield(accumulated)
            }
        }

        // If the server streamed nothing usable, surface the final text (possibly
        // empty) so the consumer still completes cleanly.
        if accumulated.isEmpty {
            continuation.yield(accumulated)
        }
    }

    /// Non-streamed single completion used for the map (per-chunk) passes.
    /// Returns the full assistant message text.
    private func completion(prompt: String, baseURL: String, apiKey: String?,
                            model: String) async throws -> String {
        let url = try endpoint(baseURL, path: "chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request, apiKey: apiKey)

        let payload = ChatRequest(
            model: model,
            messages: [.init(role: "user", content: prompt)],
            stream: false,
            maxTokens: nil,
            temperature: 0.2
        )
        request.httpBody = try encode(payload)

        let (data, response) = try await perform(request)
        try validate(response, body: data)

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message?.content ?? ""
    }

    // MARK: - Map-reduce

    /// Splits the transcript, summarizes each chunk independently (retried once on
    /// transient failure), then streams a final reduce pass over the joined
    /// partials. The non-transcript scaffold of the prompt is reused for each map
    /// call so per-chunk summaries stay on-task.
    private func summarizeMapReduce(prompt: String, baseURL: String, apiKey: String?,
                                    model: String,
                                    continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let (scaffold, transcript) = splitTranscript(prompt)
        let chunks = chunk(transcript, size: chunkSize)

        // If the transcript portion is somehow short (the bulk was elsewhere in
        // the prompt), fall back to a single streamed pass rather than degrade.
        guard chunks.count > 1 else {
            try await streamCompletion(prompt: prompt, baseURL: baseURL, apiKey: apiKey,
                                       model: model, continuation: continuation)
            return
        }

        var partials: [String] = []
        partials.reserveCapacity(chunks.count)

        for (index, piece) in chunks.enumerated() {
            try Task.checkCancellation()
            let mapPrompt = mapPromptText(scaffold: scaffold, chunk: piece,
                                          index: index, total: chunks.count)
            let partial = try await mapChunkWithRetry(prompt: mapPrompt, baseURL: baseURL,
                                                      apiKey: apiKey, model: model)
            partials.append(partial)
        }

        let reducePrompt = reducePromptText(scaffold: scaffold, partials: partials)
        try await streamCompletion(prompt: reducePrompt, baseURL: baseURL, apiKey: apiKey,
                                   model: model, continuation: continuation)
    }

    /// One map call with a single isolated retry on a transient error.
    private func mapChunkWithRetry(prompt: String, baseURL: String, apiKey: String?,
                                   model: String) async throws -> String {
        do {
            return try await completion(prompt: prompt, baseURL: baseURL,
                                        apiKey: apiKey, model: model)
        } catch {
            let mapped = mapError(error)
            if let llm = mapped as? LLMError, llm.kind.isTransient {
                try Task.checkCancellation()
                return try await completion(prompt: prompt, baseURL: baseURL,
                                            apiKey: apiKey, model: model)
            }
            throw mapped
        }
    }

    /// Returns `(scaffold, transcript)`. The scaffold is the prompt with the
    /// transcript region removed; the transcript is the text that was at
    /// `{transcript}` (already rendered by `TemplateEngine`, so the literal token
    /// is gone — we recover the body heuristically by treating the prompt as
    /// scaffold + transcript when the token is absent).
    private func splitTranscript(_ prompt: String) -> (scaffold: String, transcript: String) {
        // The rendered prompt no longer contains the literal token, so we take
        // the leading instruction block (up to the first blank-line boundary, if
        // any) as scaffold and the remainder as transcript. This keeps the
        // instructions attached to every map call while chunking the bulk text.
        if let range = prompt.range(of: "\n\n") {
            let scaffold = String(prompt[..<range.lowerBound])
            let transcript = String(prompt[range.upperBound...])
            // Only treat the head as scaffold when the transcript body is the
            // dominant part; otherwise chunk the whole thing.
            if transcript.count >= scaffold.count {
                return (scaffold, transcript)
            }
        }
        return ("", prompt)
    }

    /// Splits `text` into chunks of roughly `size` characters, preferring to
    /// break on newline boundaries so utterances aren't cut mid-word.
    private func chunk(_ text: String, size: Int) -> [String] {
        guard text.count > size else { return text.isEmpty ? [] : [text] }
        var chunks: [String] = []
        var current = ""
        current.reserveCapacity(size)

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = String(line)
            if current.count + piece.count + 1 > size, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            // A single line longer than `size` is hard-split to bound chunk size.
            if piece.count > size {
                var remainder = Substring(piece)
                while remainder.count > size {
                    let cut = remainder.index(remainder.startIndex, offsetBy: size)
                    chunks.append(String(remainder[..<cut]))
                    remainder = remainder[cut...]
                }
                current = String(remainder)
            } else {
                if !current.isEmpty { current += "\n" }
                current += piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func mapPromptText(scaffold: String, chunk: String, index: Int, total: Int) -> String {
        let header = scaffold.isEmpty ? "" : scaffold + "\n\n"
        return """
        \(header)You are summarizing part \(index + 1) of \(total) of a longer transcript. \
        Extract the key points, decisions and action items from THIS portion only; \
        do not write a conclusion yet.

        Transcript portion:
        \(chunk)
        """
    }

    private func reducePromptText(scaffold: String, partials: [String]) -> String {
        let header = scaffold.isEmpty ? "" : scaffold + "\n\n"
        let joined = partials.enumerated()
            .map { "Part \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        return """
        \(header)The transcript was summarized in \(partials.count) parts below. \
        Merge them into a single coherent summary, removing duplication and \
        preserving every decision and action item.

        \(joined)
        """
    }

    // MARK: - Networking helpers

    /// Builds `{baseURL}/{path}`, tolerating a trailing slash on `baseURL`.
    private func endpoint(_ baseURL: String, path: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LLMError(kind: .badURL, message: "The server URL is empty.")
        }
        let base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let url = URL(string: base + "/" + path),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            throw LLMError(kind: .badURL, message: "The server URL is not valid: \(baseURL)")
        }
        // Cleartext HTTP would put the API key (sent as a Bearer header) on the
        // wire in plaintext. Allow it only for loopback hosts (local LLM servers
        // like Ollama / LM Studio); require HTTPS for anything off-device.
        if scheme == "http" && !Self.isLoopback(host) {
            throw LLMError(kind: .badURL,
                           message: "Use HTTPS for non-local endpoints — plain HTTP would expose your API key.")
        }
        return url
    }

    /// Loopback hosts for which cleartext HTTP is acceptable (the request never
    /// leaves the machine).
    private static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
            || h.hasSuffix(".localhost")
    }

    private func applyAuth(_ request: inout URLRequest, apiKey: String?) {
        if let key = apiKey, !key.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw LLMError(kind: .unknown, message: "Couldn't build the request body.") }
    }

    /// Runs a request through the shared session, translating URL errors.
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw mapError(error)
        }
    }

    /// Maps HTTP status codes to typed errors. `body` is the (already buffered)
    /// response payload, inspected to distinguish a missing model.
    private func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LLMError(kind: .unknown, message: "The server returned an unexpected response.")
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw LLMError(kind: .authFailed, message: "Authentication failed — check your API key.")
        case 404:
            throw LLMError(kind: .modelNotFound, message: serverMessage(body) ?? "Model or endpoint not found.")
        case 408:
            throw LLMError(kind: .timeout, message: "The server timed out.")
        case 413:
            throw LLMError(kind: .contextOverflow, message: "The request was too large for the model's context.")
        case 400, 422:
            // Many OpenAI-compatible servers report a missing/unknown model and
            // context overflow as a 400/422 with a descriptive body.
            let detail = serverMessage(body) ?? ""
            let lower = detail.lowercased()
            if lower.contains("model") && (lower.contains("not found") || lower.contains("does not exist")
                                            || lower.contains("unknown") || lower.contains("no such")) {
                throw LLMError(kind: .modelNotFound, message: detail.isEmpty ? "Model not found." : detail)
            }
            if lower.contains("context")
                || lower.contains("maximum context")
                || (lower.contains("token") && lower.contains("exceed")) {
                throw LLMError(kind: .contextOverflow, message: detail.isEmpty ? "Context length exceeded." : detail)
            }
            throw LLMError(kind: .server, message: detail.isEmpty ? "The server rejected the request (\(http.statusCode))." : detail)
        case 500...599:
            throw LLMError(kind: .server, message: serverMessage(body) ?? "The server returned an error (\(http.statusCode)).")
        default:
            throw LLMError(kind: .unknown, message: "Unexpected status code \(http.statusCode).")
        }
    }

    /// Best-effort extraction of an OpenAI-style `{ "error": { "message": … } }`
    /// or `{ "error": "…" }` body.
    private func serverMessage(_ body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        if let env = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
            return Self.sanitize(env.error?.message ?? env.errorString)
        }
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.sanitize(text)
    }

    /// The server is user-configured but untrusted: its error body could contain
    /// control characters, escape sequences, or echoed request headers. Strip
    /// non-printables and cap the length before this text reaches the UI / logs.
    private static func sanitize(_ message: String?) -> String? {
        guard let message else { return nil }
        let cleaned = String(message.unicodeScalars.filter {
            $0 == " " || $0 == "\n" || !($0.properties.generalCategory == .control)
        })
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 512 ? String(trimmed.prefix(512)) + "…" : trimmed
    }

    /// Translates any thrown error into an `LLMError`. Already-typed `LLMError`s
    /// pass through unchanged; `URLError`s map to transport kinds.
    private func mapError(_ error: Error) -> Error {
        if let llm = error as? LLMError { return llm }
        if error is CancellationError { return error }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return LLMError(kind: .unreachable, message: "Can't reach the server — is it running?")
            case .timedOut:
                return LLMError(kind: .timeout, message: "The request timed out.")
            case .badURL, .unsupportedURL:
                return LLMError(kind: .badURL, message: "The server URL is not valid.")
            case .userAuthenticationRequired:
                return LLMError(kind: .authFailed, message: "Authentication failed — check your API key.")
            case .cancelled:
                return CancellationError()
            default:
                return LLMError(kind: .unreachable, message: urlError.localizedDescription)
            }
        }
        return LLMError(kind: .unknown, message: error.localizedDescription)
    }

    // MARK: - Wire types

    private struct ModelsResponse: Decodable {
        let data: [Model]
        struct Model: Decodable { let id: String }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let maxTokens: Int?
        let temperature: Double?

        struct Message: Encodable {
            let role: String
            let content: String
        }

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case maxTokens = "max_tokens"
        }
    }

    /// Non-streamed completion response.
    private struct ChatResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message?
            struct Message: Decodable { let content: String? }
        }
    }

    /// One SSE `data:` chunk from a streamed completion.
    private struct ChatStreamChunk: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let delta: Delta?
            struct Delta: Decodable { let content: String? }
        }
    }

    /// Tolerant decoder for both `{"error":{"message":…}}` and `{"error":"…"}`.
    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody?
        let errorString: String?

        struct ErrorBody: Decodable {
            let message: String?
            let code: String?
            let type: String?
        }

        enum CodingKeys: String, CodingKey { case error }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let body = try? container.decode(ErrorBody.self, forKey: .error) {
                self.error = body
                self.errorString = nil
            } else if let str = try? container.decode(String.self, forKey: .error) {
                self.error = nil
                self.errorString = str
            } else {
                self.error = nil
                self.errorString = nil
            }
        }
    }
}

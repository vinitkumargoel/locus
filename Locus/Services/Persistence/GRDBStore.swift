import Foundation
import GRDB
import OSLog

// MARK: - GRDB-backed MeetingStore
//
// The live persistence layer. Everything the app knows about meetings,
// transcripts, speakers, summaries, templates and per-app consent lives in a
// single SQLite database opened at:
//
//     ~/Library/Application Support/Locus/locus.sqlite
//
// Design notes:
//   • The DB is opened lazily in `bootstrap()` — `init()` never throws and never
//     touches the disk, so constructing the service (and `Services.live()`) is
//     cheap and crash-free even on a broken filesystem.
//   • A `DatabaseMigrator` owns the schema (DESIGN.md §12). Migrations are
//     additive and versioned, so an existing DB upgrades in place.
//   • Full-text search uses an FTS5 virtual table indexing every segment's text
//     plus the owning meeting's title. If FTS5 is somehow unavailable at
//     runtime the migrator falls back to LIKE-based search (still correct, just
//     slower) — search never throws because the index is missing.
//   • All public methods are `async` and hop onto GRDB's reader/writer pools via
//     the library's own `await dbQueue.read/write` APIs (available in 6.29.3),
//     so they never block the calling actor.
//   • Storage-agnostic `*Row` value types cross the protocol boundary; the GRDB
//     record structs below are private and never escape this file.

/// Live `MeetingStore` backed by SQLite via GRDB.
final class GRDBMeetingStore: MeetingStore {

    /// Opened lazily by `bootstrap()`. `nil` until then (and if the DB could not
    /// be opened, in which case every method degrades to a safe empty result).
    private var dbQueue: DatabaseQueue?

    /// Whether the FTS5 full-text index was successfully created. When false,
    /// `searchMeetings` falls back to a LIKE scan.
    private var ftsAvailable = false

    /// Absolute path to the SQLite file, resolved once at bootstrap. Used by
    /// `diskUsageBytes()` to size the DB itself.
    private var databasePath: String?

    private static let log = Logger(subsystem: "com.locus.app", category: "Store")

    /// Non-throwing: defers all heavy/throwing work to `bootstrap()`.
    init() {}

    // MARK: - Lifecycle

    /// Open (creating if needed) the database and run migrations. Idempotent:
    /// calling it twice is a no-op once the queue is live. Throws only if the
    /// support directory cannot be created or the DB cannot be opened — callers
    /// in AppState wrap this in `try?` so a failure leaves an empty, read-only-ish
    /// store rather than crashing the app.
    func bootstrap() async throws {
        if dbQueue != nil { return }

        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
        let dir = appSupport.appendingPathComponent("Locus", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("locus.sqlite")

        // Privacy hardening (P1), consistent with the app's offline posture: lock
        // the Locus support directory to 0700 and exclude it (and its audio +
        // db contents) from backups. macOS NSFileProtection is iOS-centric, so
        // restrictive POSIX perms + a backup-exclusion flag are the portable
        // equivalent. Best-effort: a perms/flag failure must not abort bootstrap.
        Self.harden(directory: dir)

        var config = Configuration()
        config.foreignKeysEnabled = true

        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try migrator().migrate(queue)

        // Lock the SQLite file to 0600 now that the queue has created it.
        Self.harden(file: dbURL)

        // Determine FTS availability from the actual schema rather than the
        // migration closure: on a second launch the migration has already run,
        // so we must re-check whether the virtual table exists.
        let ftsExists = try await queue.read { db in
            try db.tableExists("meeting_fts")
        }

        self.databasePath = dbURL.path
        self.dbQueue = queue
        self.ftsAvailable = ftsExists

        try await seedBuiltinTemplatesIfNeeded(queue)
    }

    // MARK: - Migrations / schema (DESIGN.md §12)

    private func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-core") { db in
            try db.execute(sql: """
                CREATE TABLE meeting (
                    id              TEXT PRIMARY KEY NOT NULL,
                    app             TEXT NOT NULL,
                    title           TEXT NOT NULL,
                    started_at      DOUBLE NOT NULL,
                    ended_at        DOUBLE,
                    duration_s      INTEGER NOT NULL DEFAULT 0,
                    audio_path_far  TEXT,
                    audio_path_mic  TEXT,
                    has_summary     INTEGER NOT NULL DEFAULT 0,
                    people          INTEGER NOT NULL DEFAULT 0,
                    status          TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE speaker (
                    meeting_id   TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                    key          TEXT NOT NULL,
                    label        TEXT NOT NULL,
                    display_name TEXT,
                    embedding    BLOB,
                    PRIMARY KEY (meeting_id, key)
                )
                """)

            try db.execute(sql: """
                CREATE TABLE segment (
                    id         TEXT PRIMARY KEY NOT NULL,
                    meeting_id TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                    speaker_key TEXT NOT NULL,
                    t_start    DOUBLE NOT NULL,
                    t_end      DOUBLE NOT NULL,
                    text       TEXT NOT NULL,
                    is_final   INTEGER NOT NULL DEFAULT 1,
                    is_gap     INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_segment_meeting ON segment(meeting_id)")

            try db.execute(sql: """
                CREATE TABLE summary (
                    id            TEXT PRIMARY KEY NOT NULL,
                    meeting_id    TEXT NOT NULL REFERENCES meeting(id) ON DELETE CASCADE,
                    template_id   TEXT NOT NULL,
                    template_name TEXT NOT NULL,
                    model         TEXT NOT NULL,
                    content_md    TEXT NOT NULL,
                    created_at    DOUBLE NOT NULL,
                    is_stale      INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: "CREATE INDEX idx_summary_meeting ON summary(meeting_id)")

            try db.execute(sql: """
                CREATE TABLE template (
                    id         TEXT PRIMARY KEY NOT NULL,
                    name       TEXT NOT NULL,
                    prompt     TEXT NOT NULL,
                    is_builtin INTEGER NOT NULL DEFAULT 0
                )
                """)

            try db.execute(sql: """
                CREATE TABLE app_consent (
                    bundle_id TEXT PRIMARY KEY NOT NULL,
                    mode      TEXT NOT NULL
                )
                """)
        }

        // FTS5 full-text index over segment text + meeting title. We keep it as
        // a manually-populated (raw-content) table so we can index two different
        // source tables under one search surface, and so a delete/replace on
        // segments stays cheap. Columns:
        //   • meeting_id — the join key back to `meeting` (we search by `text`
        //     and collect distinct meeting ids).
        //   • kind       — 'title' or 'segment', so we can re-index one source
        //     without disturbing the other.
        //   • text       — the searchable content.
        // `meeting_id` and `kind` are marked UNINDEXED so the tokenizer ignores
        // them and a MATCH only ever hits `text`.
        migrator.registerMigration("v2-fts") { db in
            do {
                try db.create(virtualTable: "meeting_fts", using: FTS5()) { t in
                    t.tokenizer = .porter(wrapping: .unicode61())
                    t.column("meeting_id").notIndexed()
                    t.column("kind").notIndexed()
                    t.column("text")
                }
            } catch {
                // FTS5 not compiled into this SQLite build: skip the virtual
                // table. `searchMeetings` falls back to LIKE (bootstrap detects
                // the missing table via `tableExists`). Never fatal — but log it
                // so a real schema error here isn't mistaken for "FTS absent".
                Self.log.notice("FTS5 virtual table not created; search will use the LIKE fallback (\(error.localizedDescription, privacy: .public))")
            }
        }

        return migrator
    }

    /// On the very first launch (empty `template` table) install the four
    /// built-in presets with the exact prompt bodies from `SampleData`.
    private func seedBuiltinTemplatesIfNeeded(_ queue: DatabaseQueue) async throws {
        try await queue.write { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM template WHERE is_builtin = 1") ?? 0
            guard count == 0 else { return }
            let builtins: [(String, String)] = [
                ("t1", "Long Summary"),
                ("t2", "One-on-One"),
                ("t3", "Action Items & Decisions"),
                ("t4", "Quick Notes / Standup"),
            ]
            for (id, name) in builtins {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO template (id, name, prompt, is_builtin)
                    VALUES (:id, :name, :prompt, 1)
                    """, arguments: ["id": id, "name": name, "prompt": SampleData.templateBody(id)])
            }
        }
    }

    // MARK: - Reads

    func allMeetings() async throws -> [MeetingRow] {
        guard let queue = dbQueue else { return [] }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM meeting ORDER BY started_at DESC")
                .map(Self.meetingRow)
        }
    }

    func searchMeetings(_ query: String) async throws -> [MeetingRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return try await allMeetings() }
        guard let queue = dbQueue else { return [] }

        let useFTS = ftsAvailable
        return try await queue.read { db in
            if useFTS, let pattern = FTS5Pattern(matchingAnyTokenIn: q) {
                // Match against the FTS index, then de-dupe meeting ids and
                // return full meeting rows newest-first.
                let ids = try String.fetchAll(db, sql: """
                    SELECT DISTINCT meeting_id FROM meeting_fts WHERE meeting_fts MATCH ?
                    """, arguments: [pattern])
                if ids.isEmpty { return [] }
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT * FROM meeting WHERE id IN (\(placeholders)) ORDER BY started_at DESC
                    """, arguments: StatementArguments(ids))
                return rows.map(Self.meetingRow)
            } else {
                // LIKE fallback: match the title directly, or any segment text.
                let like = "%\(Self.escapeLike(q))%"
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT m.* FROM meeting m
                    LEFT JOIN segment s ON s.meeting_id = m.id
                    WHERE m.title LIKE :like ESCAPE '\\'
                       OR s.text  LIKE :like ESCAPE '\\'
                    ORDER BY m.started_at DESC
                    """, arguments: ["like": like])
                return rows.map(Self.meetingRow)
            }
        }
    }

    func meeting(id: String) async throws -> MeetingRow? {
        guard let queue = dbQueue else { return nil }
        return try await queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM meeting WHERE id = ?", arguments: [id])
                .map(Self.meetingRow)
        }
    }

    func segments(meetingId: String) async throws -> [SegmentRow] {
        guard let queue = dbQueue else { return [] }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM segment WHERE meeting_id = ? ORDER BY t_start ASC
                """, arguments: [meetingId])
                .map(Self.segmentRow)
        }
    }

    func speakers(meetingId: String) async throws -> [SpeakerRow] {
        guard let queue = dbQueue else { return [] }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM speaker WHERE meeting_id = ? ORDER BY key ASC
                """, arguments: [meetingId])
                .map(Self.speakerRow)
        }
    }

    func summaries(meetingId: String) async throws -> [SummaryRow] {
        guard let queue = dbQueue else { return [] }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM summary WHERE meeting_id = ? ORDER BY created_at DESC
                """, arguments: [meetingId])
                .map(Self.summaryRow)
        }
    }

    // MARK: - Writes

    @discardableResult
    func createMeeting(app: String, title: String, startedAt: Date) async throws -> MeetingRow {
        let row = MeetingRow(
            id: "m-\(UUID().uuidString.lowercased())",
            title: title,
            app: app,
            startedAt: startedAt,
            durationSec: 0,
            people: 0,
            hasSummary: false,
            status: .recording,
            audioFarPath: nil,
            audioMicPath: nil
        )
        guard let queue = dbQueue else { return row }
        try await queue.write { [ftsAvailable] db in
            try db.execute(sql: """
                INSERT INTO meeting
                    (id, app, title, started_at, ended_at, duration_s,
                     audio_path_far, audio_path_mic, has_summary, people, status)
                VALUES
                    (:id, :app, :title, :started, NULL, 0,
                     NULL, NULL, 0, 0, :status)
                """, arguments: [
                    "id": row.id, "app": row.app, "title": row.title,
                    "started": row.startedAt.timeIntervalSince1970,
                    "status": row.status.rawValue,
                ])
            if ftsAvailable { try Self.indexTitle(db, meetingId: row.id, title: row.title) }
        }
        return row
    }

    func appendSegment(_ segment: SegmentRow) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { [ftsAvailable] db in
            try Self.insertSegment(db, segment)
            if ftsAvailable {
                try Self.indexSegment(db, segment)
            }
        }
    }

    func replaceSegments(meetingId: String, _ segments: [SegmentRow]) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { [ftsAvailable] db in
            try db.execute(sql: "DELETE FROM segment WHERE meeting_id = ?", arguments: [meetingId])
            if ftsAvailable {
                // Drop only this meeting's *segment* FTS rows; the title row
                // (kind = 'title') is left intact.
                try db.execute(sql: """
                    DELETE FROM meeting_fts WHERE meeting_id = ? AND kind = 'segment'
                    """, arguments: [meetingId])
            }
            for seg in segments {
                try Self.insertSegment(db, seg)
                if ftsAvailable { try Self.indexSegment(db, seg) }
            }
        }
    }

    func upsertSpeaker(_ speaker: SpeakerRow) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO speaker (meeting_id, key, label, display_name)
                VALUES (:meeting, :key, :label, :display)
                ON CONFLICT(meeting_id, key) DO UPDATE SET
                    label = excluded.label,
                    display_name = excluded.display_name
                """, arguments: [
                    "meeting": speaker.meetingId, "key": speaker.key,
                    "label": speaker.label, "display": speaker.displayName,
                ])
        }
    }

    func finalizeMeeting(id: String, durationSec: Int, status: MeetingStatus,
                         audioFarPath: String?, audioMicPath: String?) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            // Derive the participant count from the distinct speakers actually
            // present in the transcript — a single authority so the library/detail
            // "N people" can never disagree with the transcript itself.
            let people = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT speaker_key) FROM segment WHERE meeting_id = ?
                """, arguments: [id]) ?? 0
            try db.execute(sql: """
                UPDATE meeting SET
                    duration_s = :dur,
                    status = :status,
                    audio_path_far = :far,
                    audio_path_mic = :mic,
                    people = :people,
                    ended_at = COALESCE(ended_at, started_at + :dur)
                WHERE id = :id
                """, arguments: [
                    "dur": durationSec, "status": status.rawValue,
                    "far": audioFarPath, "mic": audioMicPath,
                    "people": people, "id": id,
                ])
        }
    }

    func renameMeeting(id: String, title: String) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { [ftsAvailable] db in
            try db.execute(sql: "UPDATE meeting SET title = ? WHERE id = ?", arguments: [title, id])
            if ftsAvailable {
                // Keep the title row in the FTS index in sync.
                try db.execute(sql: """
                    DELETE FROM meeting_fts WHERE meeting_id = ? AND kind = 'title'
                    """, arguments: [id])
                try Self.indexTitle(db, meetingId: id, title: title)
            }
        }
    }

    func renameSpeaker(meetingId: String, key: String, displayName: String?) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            // Upsert so renaming a speaker the engine hasn't persisted yet still works.
            let label = try String.fetchOne(db, sql: """
                SELECT label FROM speaker WHERE meeting_id = ? AND key = ?
                """, arguments: [meetingId, key]) ?? Self.defaultLabel(for: key)
            try db.execute(sql: """
                INSERT INTO speaker (meeting_id, key, label, display_name)
                VALUES (:meeting, :key, :label, :display)
                ON CONFLICT(meeting_id, key) DO UPDATE SET display_name = excluded.display_name
                """, arguments: [
                    "meeting": meetingId, "key": key, "label": label, "display": displayName,
                ])
        }
    }

    func updateSegmentText(id: String, text: String) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { [ftsAvailable] db in
            let meetingId = try String.fetchOne(db, sql: "SELECT meeting_id FROM segment WHERE id = ?",
                                                 arguments: [id])
            try db.execute(sql: "UPDATE segment SET text = ? WHERE id = ?", arguments: [text, id])
            if let mid = meetingId {
                // Editing the transcript invalidates any generated summary, in the
                // same transaction so the two can never drift apart.
                try db.execute(sql: "UPDATE summary SET is_stale = 1 WHERE meeting_id = ?",
                               arguments: [mid])
            }
            if ftsAvailable, let mid = meetingId {
                // Rebuild this meeting's segment FTS rows from the (now updated)
                // segment table — simplest way to keep the index consistent
                // without tracking individual FTS rowids.
                try db.execute(sql: "DELETE FROM meeting_fts WHERE meeting_id = ? AND kind = 'segment'",
                               arguments: [mid])
                let segs = try Row.fetchAll(db, sql: "SELECT * FROM segment WHERE meeting_id = ?",
                                            arguments: [mid]).map(Self.segmentRow)
                for seg in segs { try Self.indexSegment(db, seg) }
            }
        }
    }

    func markSummariesStale(meetingId: String) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            try db.execute(sql: "UPDATE summary SET is_stale = 1 WHERE meeting_id = ?",
                           arguments: [meetingId])
        }
    }

    func saveSummary(_ summary: SummaryRow) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO summary
                    (id, meeting_id, template_id, template_name, model, content_md, created_at, is_stale)
                VALUES
                    (:id, :meeting, :tid, :tname, :model, :content, :created, :stale)
                ON CONFLICT(id) DO UPDATE SET
                    template_id = excluded.template_id,
                    template_name = excluded.template_name,
                    model = excluded.model,
                    content_md = excluded.content_md,
                    created_at = excluded.created_at,
                    is_stale = excluded.is_stale
                """, arguments: [
                    "id": summary.id, "meeting": summary.meetingId,
                    "tid": summary.templateId, "tname": summary.templateName,
                    "model": summary.model, "content": summary.contentMD,
                    "created": summary.createdAt.timeIntervalSince1970,
                    "stale": summary.isStale ? 1 : 0,
                ])
            try db.execute(sql: "UPDATE meeting SET has_summary = 1 WHERE id = ?",
                           arguments: [summary.meetingId])
        }
    }

    func deleteMeeting(id: String) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { [ftsAvailable] db in
            // Cascades remove speaker/segment/summary rows via the FK ON DELETE.
            if ftsAvailable {
                try db.execute(sql: "DELETE FROM meeting_fts WHERE meeting_id = ?", arguments: [id])
            }
            try db.execute(sql: "DELETE FROM meeting WHERE id = ?", arguments: [id])
        }
    }

    func deleteAllMeetings() async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { [ftsAvailable] db in
            if ftsAvailable {
                try db.execute(sql: "DELETE FROM meeting_fts")
            }
            // Cascade clears speaker/segment/summary; templates + consent survive.
            try db.execute(sql: "DELETE FROM meeting")
        }
    }

    // MARK: - Templates

    func templates() async throws -> [TemplateRow] {
        guard let queue = dbQueue else { return [] }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM template ORDER BY is_builtin DESC, name ASC
                """)
                .map(Self.templateRow)
        }
    }

    func saveTemplate(_ template: TemplateRow) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO template (id, name, prompt, is_builtin)
                VALUES (:id, :name, :prompt, :builtin)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    prompt = excluded.prompt,
                    is_builtin = excluded.is_builtin
                """, arguments: [
                    "id": template.id, "name": template.name,
                    "prompt": template.prompt, "builtin": template.isBuiltin ? 1 : 0,
                ])
        }
    }

    func deleteTemplate(id: String) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM template WHERE id = ?", arguments: [id])
        }
    }

    // MARK: - Consent

    func consentMode(bundleId: String) async throws -> ConsentMode? {
        guard let queue = dbQueue else { return nil }
        return try await queue.read { db in
            guard let raw = try String.fetchOne(db, sql: """
                SELECT mode FROM app_consent WHERE bundle_id = ?
                """, arguments: [bundleId]) else { return nil }
            return ConsentMode(rawValue: raw)
        }
    }

    func setConsentMode(bundleId: String, mode: ConsentMode) async throws {
        guard let queue = dbQueue else { return }
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO app_consent (bundle_id, mode) VALUES (:bid, :mode)
                ON CONFLICT(bundle_id) DO UPDATE SET mode = excluded.mode
                """, arguments: ["bid": bundleId, "mode": mode.rawValue])
        }
    }

    // MARK: - Recovery + disk usage

    /// Rows still flagged `.recording`/`.processing` at launch — i.e. meetings
    /// that were interrupted by a crash/quit before they were finalized.
    func recoverableMeetings() async throws -> [MeetingRow] {
        guard let queue = dbQueue else { return [] }
        return try await queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM meeting WHERE status IN ('recording', 'processing')
                ORDER BY started_at DESC
                """)
                .map(Self.meetingRow)
        }
    }

    /// Sum of (a) the on-disk size of every referenced audio file and (b) the
    /// SQLite database file (including its -wal / -shm sidecars). Missing files
    /// contribute zero rather than failing the whole calculation.
    func diskUsageBytes() async throws -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default

        if let queue = dbQueue {
            let paths: [String] = try await queue.read { db in
                let far = try String.fetchAll(db, sql: "SELECT audio_path_far FROM meeting WHERE audio_path_far IS NOT NULL")
                let mic = try String.fetchAll(db, sql: "SELECT audio_path_mic FROM meeting WHERE audio_path_mic IS NOT NULL")
                return far + mic
            }
            for path in Set(paths) {
                total += Self.fileSize(at: path, fm: fm)
            }
        }

        if let dbPath = databasePath {
            for suffix in ["", "-wal", "-shm"] {
                total += Self.fileSize(at: dbPath + suffix, fm: fm)
            }
        }
        return total
    }

    // MARK: - Private helpers

    private static func fileSize(at path: String, fm: FileManager) -> Int64 {
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Best-effort directory hardening: `0700` perms + exclude-from-backup.
    /// Applied unconditionally so an existing directory is also locked down.
    /// Never throws — a perms/flag failure is logged, not propagated.
    private static func harden(directory url: URL) {
        let fm = FileManager.default
        do {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            log.notice("Could not set 0700 on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        var dir = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try dir.setResourceValues(values)
        } catch {
            log.notice("Could not exclude \(url.lastPathComponent, privacy: .public) from backup: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Best-effort `0600` on the SQLite file. Never throws.
    private static func harden(file url: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.notice("Could not set 0600 on \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Insert a single segment row (no FTS — caller decides).
    private static func insertSegment(_ db: Database, _ s: SegmentRow) throws {
        try db.execute(sql: """
            INSERT INTO segment (id, meeting_id, speaker_key, t_start, t_end, text, is_final, is_gap)
            VALUES (:id, :meeting, :spk, :ts, :te, :text, :final, :gap)
            ON CONFLICT(id) DO UPDATE SET
                speaker_key = excluded.speaker_key,
                t_start = excluded.t_start,
                t_end = excluded.t_end,
                text = excluded.text,
                is_final = excluded.is_final,
                is_gap = excluded.is_gap
            """, arguments: [
                "id": s.id, "meeting": s.meetingId, "spk": s.speakerKey,
                "ts": s.tStart, "te": s.tEnd, "text": s.text,
                "final": s.isFinal ? 1 : 0, "gap": s.isGap ? 1 : 0,
            ])
    }

    /// Add a segment's text to the FTS index (skips empty/gap rows).
    private static func indexSegment(_ db: Database, _ s: SegmentRow) throws {
        guard !s.isGap, !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try db.execute(sql: "INSERT INTO meeting_fts (meeting_id, kind, text) VALUES (?, 'segment', ?)",
                       arguments: [s.meetingId, s.text])
    }

    /// Add a meeting title to the FTS index.
    private static func indexTitle(_ db: Database, meetingId: String, title: String) throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try db.execute(sql: "INSERT INTO meeting_fts (meeting_id, kind, text) VALUES (?, 'title', ?)",
                       arguments: [meetingId, title])
    }

    /// Escape `%`, `_`, and `\` for a LIKE pattern (we use `\` as the ESCAPE char).
    private static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// System label for a speaker key when none is stored: "s1" -> "You",
    /// "s2" -> "Speaker 2", etc. Mirrors the prototype's convention.
    private static func defaultLabel(for key: String) -> String {
        if key == "s1" { return "You" }
        if key.hasPrefix("s"), let n = Int(key.dropFirst()) { return "Speaker \(n)" }
        return key
    }

    // MARK: - Row mapping (GRDB Row -> public *Row value types)

    private static func meetingRow(_ row: Row) -> MeetingRow {
        let statusRaw: String = row["status"]
        return MeetingRow(
            id: row["id"],
            title: row["title"],
            app: row["app"],
            startedAt: Date(timeIntervalSince1970: row["started_at"]),
            durationSec: row["duration_s"],
            people: row["people"],
            hasSummary: (row["has_summary"] as Int) != 0,
            status: MeetingStatus(rawValue: statusRaw) ?? .ready,
            audioFarPath: row["audio_path_far"],
            audioMicPath: row["audio_path_mic"]
        )
    }

    private static func segmentRow(_ row: Row) -> SegmentRow {
        SegmentRow(
            id: row["id"],
            meetingId: row["meeting_id"],
            speakerKey: row["speaker_key"],
            tStart: row["t_start"],
            tEnd: row["t_end"],
            text: row["text"],
            isFinal: (row["is_final"] as Int) != 0,
            isGap: (row["is_gap"] as Int) != 0
        )
    }

    private static func speakerRow(_ row: Row) -> SpeakerRow {
        SpeakerRow(
            meetingId: row["meeting_id"],
            key: row["key"],
            label: row["label"],
            displayName: row["display_name"]
        )
    }

    private static func summaryRow(_ row: Row) -> SummaryRow {
        SummaryRow(
            id: row["id"],
            meetingId: row["meeting_id"],
            templateId: row["template_id"],
            templateName: row["template_name"],
            model: row["model"],
            contentMD: row["content_md"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            isStale: (row["is_stale"] as Int) != 0
        )
    }

    private static func templateRow(_ row: Row) -> TemplateRow {
        TemplateRow(
            id: row["id"],
            name: row["name"],
            prompt: row["prompt"],
            isBuiltin: (row["is_builtin"] as Int) != 0
        )
    }
}

# Releasing Locus

Locus is distributed **outside the Mac App Store**. The App Sandbox blocks the
CoreAudio process-tap that Locus uses to capture meeting audio, so the app ships
as a **Developer ID + notarized** build with the **Hardened Runtime** enabled.

This document is the end-to-end release runbook: prerequisites, then
**build → notarize → staple → verify → distribute**. The `scripts/notarize.sh`
helper automates the middle of this pipeline.

---

## 1. Prerequisites (one-time)

1. **Apple Developer Program membership** (paid). Required to issue a
   Developer ID certificate and to use the notary service.

2. **Developer ID Application certificate + private key in your keychain.**
   In Xcode: *Settings → Accounts → (your team) → Manage Certificates → +
   → Developer ID Application*. Confirm it is present and valid:

   ```bash
   security find-identity -v -p codesigning
   ```

   You should see an identity named like
   `Developer ID Application: Your Name (ABCDE12345)`. The trailing
   10-character string is your **Team ID**.

3. **Set the Team ID in `project.yml`.** Replace the `DEVELOPMENT_TEAM:
   YOUR_TEAM_ID` placeholder with your real Team ID, then regenerate:

   ```bash
   xcodegen generate
   ```

   Debug keeps `CODE_SIGN_STYLE: Automatic`; Release uses Manual signing with
   the `Developer ID Application` identity. CI continues to build Debug with
   `CODE_SIGNING_ALLOWED=NO`, so the placeholder never blocks CI.

4. **Store a notarytool credential profile** (saves an app-specific password in
   the keychain so you never type it again). First create an app-specific
   password at <https://appleid.apple.com> → *Sign-In and Security →
   App-Specific Passwords*, then:

   ```bash
   xcrun notarytool store-credentials "LocusNotary" \
     --apple-id "you@example.com" \
     --team-id "ABCDE12345" \
     --password "abcd-efgh-ijkl-mnop"   # the app-specific password
   ```

   `LocusNotary` is the profile name referenced by `scripts/notarize.sh`
   (override with the `NOTARY_PROFILE` env var if you choose another name).

5. **Tools on PATH:** Xcode + command-line tools (provides `xcodebuild`,
   `xcrun notarytool`, `xcrun stapler`) and `xcodegen`
   (`brew install xcodegen`).

---

## 2. Build → notarize → staple (one command)

With the prerequisites in place, run the helper. Set the placeholders as
environment variables (or edit the defaults at the top of the script):

```bash
TEAM_ID="ABCDE12345" \
SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
NOTARY_PROFILE="LocusNotary" \
  ./scripts/notarize.sh
```

The script (fail-fast, echoing each step):

1. `xcodegen generate` — regenerate the project from `project.yml`.
2. `xcodebuild archive` — Release archive, Hardened Runtime, Manual Developer
   ID signing.
3. `xcodebuild -exportArchive` — export a signed `.app` using a `developer-id`
   export options plist (written inline to `build/ExportOptions.plist`).
4. `ditto -c -k --keepParent` — zip the `.app` for submission.
5. `xcrun notarytool submit --wait` — upload to Apple and block until the
   notary service returns `Accepted` (or fails).
6. `xcrun stapler staple` — attach the notarization ticket to the `.app` so it
   validates offline.
7. `xcrun stapler validate` + `spctl --assess` — verify the result.

Output artifact: `build/export/Locus.app` (notarized + stapled).

### If notarization fails

Get the detailed log for a submission to see which binary/entitlement was
rejected:

```bash
xcrun notarytool history --keychain-profile "LocusNotary"
xcrun notarytool log <submission-id> --keychain-profile "LocusNotary"
```

Common causes: a nested binary missing the Hardened Runtime, an unsigned
dependency, or a missing `--options runtime` on a manual `codesign`. The
xcodebuild archive path here signs with the Hardened Runtime automatically.

---

## 3. Verify

Confirm Gatekeeper will accept the app as if downloaded by a user:

```bash
# Ticket is stapled and valid:
xcrun stapler validate build/export/Locus.app

# Gatekeeper assessment for a launchable app:
spctl --assess --type execute --verbose build/export/Locus.app
# expected: "accepted" + "source=Notarized Developer ID"

# Inspect the signature, Team ID, and that runtime hardening is on:
codesign --display --verbose=4 build/export/Locus.app
```

---

## 4. Distribute

Notarization travels with the artifact you ship, so choose one:

- **Zipped app.** Re-zip the *stapled* app (the staple in step 2 is on the
   `.app`, so zip after stapling):

   ```bash
   ditto -c -k --keepParent build/export/Locus.app build/Locus.zip
   ```

- **Disk image (recommended for end users).** Create a `.dmg`, then sign,
   notarize, and staple the **dmg** as well (the same notarytool/stapler steps,
   pointed at the `.dmg`):

   ```bash
   hdiutil create -volname Locus -srcfolder build/export/Locus.app \
     -ov -format UDZO build/Locus.dmg
   codesign --sign "Developer ID Application: Your Name (ABCDE12345)" build/Locus.dmg
   xcrun notarytool submit build/Locus.dmg --keychain-profile "LocusNotary" --wait
   xcrun stapler staple build/Locus.dmg
   ```

Upload the resulting `.zip` or `.dmg` to your distribution channel (GitHub
Releases, website, etc.). Because the ticket is stapled, the app launches
cleanly on a fresh machine **without** an internet check.

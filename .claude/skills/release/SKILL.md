---
name: release
description: Release a new ClaudeBar version end-to-end - bump pubspec version, commit, build/sign/notarize the DMG via rps ship, tag, and publish a GitHub release with the DMG attached. Use when the user asks to release, ship, or publish a new version (e.g. "ขึ้น release", "ออกเวอร์ชันใหม่", "release เวอร์ชันใหม่", "ship it").
---

# ClaudeBar Release

Releases follow one fixed pipeline. Do the steps in order; do not skip the
verifications. The whole flow was validated on the v1.2.0 release (2026-06-12).

## Sparkle auto-update signing key (CRITICAL — read before touching releases)

ClaudeBar updates itself via Sparkle (the `auto_updater` package). The entire
chain hangs on ONE EdDSA private key:

- Its public half (`SUPublicEDKey`) is baked into every shipped build's
  `macos/Runner/Info.plist`. Sparkle in users' already-installed copies only
  accepts an update archive signed by that exact private key.
- The private key lives in the **login Keychain** (open Keychain Access, search
  `sparkle` — the EdDSA "private key" item). It is NOT in git.
- **It cannot be regenerated.** `generate_keys` mints a fresh RANDOM key that
  will NOT match the public key already shipped. Lose the key + generate a new
  one ⇒ every existing user silently stops receiving updates and must reinstall
  ClaudeBar by hand. So: keep a backup, never regenerate casually.

The Sparkle CLI tools live at `macos/Pods/Sparkle/bin/*` after `pod install`.

### First-time setup (done once; here for a fresh machine)
```bash
fvm flutter pub get
(cd macos && pod install)                       # provides Pods/Sparkle/bin/*
dart run auto_updater:generate_keys             # prints the base64 public key
# Paste it into macos/Runner/Info.plist:
#   <key>SUPublicEDKey</key><string>…</string>
```

### Back up the private key (do this immediately after generating)
```bash
# Export from Keychain to a file → store the file in a password manager
# (1Password etc.), then delete the local copy. NEVER commit it (*.key is
# .gitignored, but keep it out of the repo entirely).
macos/Pods/Sparkle/bin/generate_keys -x ~/claudebar-sparkle-private.key
```

### Restore it (new Mac / CI / after an accidental Keychain delete)
```bash
macos/Pods/Sparkle/bin/generate_keys -f ~/claudebar-sparkle-private.key
# Verify: with a key present, re-running generate_keys just reprints the public
# key — it must equal SUPublicEDKey in Info.plist.
dart run auto_updater:generate_keys
```

### Worst case: key gone AND no backup
Unrecoverable. Generate a new key, put the new `SUPublicEDKey` in Info.plist,
ship a new build, and tell existing users to download it manually (their copy
cannot auto-update across the key change). The backup is how you avoid this.

### Appcast hosting (one-time)
`docs/appcast.xml` is served via GitHub Pages at
`https://beerbeatbox.github.io/claudebar/appcast.xml` (the feed URL hardcoded in
`lib/main.dart`). Enable it once: repo Settings → Pages → "Deploy from a branch"
→ branch `main`, folder `/docs`.

## 0. Pre-flight (abort early if any fails)

```bash
git status --short          # must be clean (or only changes user wants released)
git log origin/main..HEAD   # everything must be pushed before shipping
flutter analyze             # must report "No issues found"
flutter test                # all tests must pass
```

If the tree has uncommitted work, stop and ask the user whether to commit it
first (suggest /commit-push) — never release uncommitted code.

## 1. Decide the new version

- Read the current version from `pubspec.yaml` (format `X.Y.Z+N`).
- Look at `git log v<last-tag>..HEAD --oneline`:
  - any `feat:` commit → **minor** bump (1.1.0 → 1.2.0)
  - only `fix:`/`chore:`/`docs:`/`test:` → **patch** bump (1.2.0 → 1.2.1)
  - breaking change → ask the user.
- Always increment the build number `+N` by 1.
- Tell the user the chosen version + a draft of the release notes (step 4)
  **before** building, so a wrong version never gets notarized.

## 2. Bump, commit, push

```bash
# edit pubspec.yaml: version: X.Y.Z+N
git add pubspec.yaml
git commit -m "chore: bump version to X.Y.Z"
git push
```

## 3. Build, sign, notarize — `rps ship`

```bash
rps ship 2>&1 | tee /tmp/claudebar-ship.log
```

- Run it in the background and watch progress (`==>` lines); the full
  pipeline is: flutter build → sign frameworks → sign app → make DMG →
  sign DMG → notarytool submit → wait → staple → Gatekeeper verify.
- Takes ~5-10 minutes; the notary wait is the long pole (1-5 min).
- Success looks like: `Done: build/dist/ClaudeBar-X.Y.Z.dmg — ready to share.`
- The script also produces `build/dist/ClaudeBar-X.Y.Z.zip` (the Sparkle update
  enclosure — a stapled, ditto-zipped `.app`) and prints the appcast signature:
  `sparkle:edSignature="…" length="…"`. **Copy that line** — step 5b needs it.
- The script is resumable: if interrupted after submission, just re-run it —
  it picks up the pending submission id from `build/dist/.notary-submission-id`
  instead of rebuilding.
- Requirements already configured on this machine: a "Developer ID
  Application" cert in the login keychain and notary credentials under the
  profile `claudebar-notary`. If either is missing the script says so —
  surface the error to the user, don't try to work around signing.

## 4. Release notes

Collect user-facing changes since the previous tag:

```bash
git log v<prev>..HEAD --oneline
```

Match the style of previous releases (`gh release view v1.2.0`):
- Heading `### Changes`, then bullets.
- Bullets describe what the **user** experiences, not the code ("No more
  Keychain password pop-ups", not "add CliUsageSource"). Bold the headline
  benefit of the release in the first bullet.
- Skip `test:`/`chore:` commits unless they matter to users.
- Show the notes to the user for approval before publishing (step 1 covers
  this if done together with the version proposal).

## 5. Tag + GitHub release

Attach BOTH the `.dmg` (first-time human download) and the `.zip` (Sparkle's
update enclosure) so the appcast URL in step 5b resolves.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh release create vX.Y.Z \
  build/dist/ClaudeBar-X.Y.Z.dmg build/dist/ClaudeBar-X.Y.Z.zip \
  --title "ClaudeBar X.Y.Z" \
  --notes "<the approved notes>"
```

## 5b. Publish the appcast (this is what triggers the in-app update)

The GitHub release must exist first (the enclosure URL points at its `.zip`).
Prepend a new `<item>` to `docs/appcast.xml` (newest first, just below
`<language>`), using the `edSignature` + `length` printed by `rps ship` in step 3:

```xml
    <item>
      <title>Version X.Y.Z</title>
      <sparkle:version>N</sparkle:version>                <!-- = pubspec +N / CFBundleVersion -->
      <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>10.15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[ <ul><li>…approved notes as HTML…</li></ul> ]]></description>
      <pubDate>Wed, 17 Jun 2026 10:00:00 +0000</pubDate>
      <enclosure
        url="https://github.com/beerbeatbox/claudebar/releases/download/vX.Y.Z/ClaudeBar-X.Y.Z.zip"
        sparkle:os="macos"
        sparkle:edSignature="<from rps ship>"
        length="<from rps ship>"
        type="application/octet-stream" />
    </item>
```

`sparkle:version` MUST be the build number `N` (strictly increasing) — it is what
Sparkle compares. Then commit + push so GitHub Pages serves the new feed:

```bash
git add docs/appcast.xml
git commit -m "chore: appcast for vX.Y.Z"
git push
```

Lost the `edSignature`/`length`? Regenerate without rebuilding:
`dart run auto_updater:sign_update build/dist/ClaudeBar-X.Y.Z.zip`.

## 6. Verify and report

```bash
gh release view vX.Y.Z --json name,tagName,assets -q '.name + " | " + .tagName + " | " + .assets[0].name'
```

Confirm the DMG asset is attached, then report the release URL
(`https://github.com/beerbeatbox/claudebar/releases/tag/vX.Y.Z`) to the user
with a one-line summary of what shipped.

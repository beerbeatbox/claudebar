---
name: release
description: Release a new ClaudeBar version end-to-end - bump pubspec version, commit, build/sign/notarize the DMG via rps ship, tag, and publish a GitHub release with the DMG attached. Use when the user asks to release, ship, or publish a new version (e.g. "ขึ้น release", "ออกเวอร์ชันใหม่", "release เวอร์ชันใหม่", "ship it").
---

# ClaudeBar Release

Releases follow one fixed pipeline. Do the steps in order; do not skip the
verifications. The whole flow was validated on the v1.2.0 release (2026-06-12).

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

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh release create vX.Y.Z build/dist/ClaudeBar-X.Y.Z.dmg \
  --title "ClaudeBar X.Y.Z" \
  --notes "<the approved notes>"
```

## 6. Verify and report

```bash
gh release view vX.Y.Z --json name,tagName,assets -q '.name + " | " + .tagName + " | " + .assets[0].name'
```

Confirm the DMG asset is attached, then report the release URL
(`https://github.com/beerbeatbox/claudebar/releases/tag/vX.Y.Z`) to the user
with a one-line summary of what shipped.

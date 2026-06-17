#!/usr/bin/env bash
#
# Build, sign, package, notarize, and staple a distributable ClaudeBar DMG.
#
# One-time setup required first:
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application)
#   2. Notary credentials stored under the profile "claudebar-notary":
#      xcrun notarytool store-credentials claudebar-notary \
#        --apple-id <apple-id-email> --team-id <TEAM_ID>
#
# Usage:
#   rps ship            # or: scripts/release_dmg.sh
#
# Safe to interrupt: the submission id is saved next to the DMG, so a re-run
# resumes the pending notarization (wait → staple) instead of rebuilding.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ClaudeBar"
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
ENTITLEMENTS="macos/Runner/Release.entitlements"
NOTARY_PROFILE="claudebar-notary"
VERSION="$(sed -n 's/^version: \([0-9.]*\).*/\1/p' pubspec.yaml)"
DMG_PATH="build/dist/${APP_NAME}-${VERSION}.dmg"
ZIP_PATH="build/dist/${APP_NAME}-${VERSION}.zip"
ID_FILE="build/dist/.notary-submission-id"
# Sign tool ships inside the Sparkle pod once `pod install` has run.
SIGN_UPDATE="macos/Pods/Sparkle/bin/sign_update"

submission_status() {
  xcrun notarytool info "$1" --keychain-profile "$NOTARY_PROFILE" 2>/dev/null \
    | awk -F': ' '/status:/{print $2; exit}'
}

staple_and_verify() {
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"
  echo "==> Verifying Gatekeeper acceptance"
  spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
  rm -f "$ID_FILE"
  build_sparkle_zip
  echo
  echo "Done: $DMG_PATH — ready to share."
}

# Build the Sparkle update enclosure: a ditto-zip of the .app (NOT the DMG —
# DMG packaging can strip the exec bit off Sparkle helpers and break installs;
# ditto preserves the framework symlinks + code signatures). Staple the .app so
# it verifies offline too (its cdhash was notarized as part of the DMG submit),
# then print the appcast signature for the human to paste into docs/appcast.xml.
build_sparkle_zip() {
  echo "==> Stapling the .app for the Sparkle update zip"
  xcrun stapler staple "$APP_PATH" \
    || echo "warn: could not staple .app — the zip still verifies online."
  echo "==> Building Sparkle update zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
  echo "Created $ZIP_PATH"
  if [[ -x "$SIGN_UPDATE" ]]; then
    echo "==> Appcast signature for v${VERSION} (paste into docs/appcast.xml <enclosure>):"
    # CI has no EdDSA key in the Keychain (and a Keychain ACL prompt would hang a
    # headless runner), so point sign_update at a key file when SPARKLE_KEY_FILE
    # is set; locally it stays unset and the key is read from the Keychain.
    if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
      "$SIGN_UPDATE" "$ZIP_PATH" -f "$SPARKLE_KEY_FILE"
    else
      "$SIGN_UPDATE" "$ZIP_PATH"
    fi
  else
    echo "note: $SIGN_UPDATE not found. Run 'pod install' (macos/), then:" >&2
    echo "      dart run auto_updater:sign_update \"$ZIP_PATH\"" >&2
  fi
}

finish_submission() {
  local id="$1" status
  status="$(submission_status "$id")"
  if [[ "$status" == "In Progress" ]]; then
    echo "==> Waiting for Apple notary service (id: $id)"
    xcrun notarytool wait "$id" --keychain-profile "$NOTARY_PROFILE" || true
    status="$(submission_status "$id")"
  fi
  case "$status" in
    Accepted)
      staple_and_verify
      exit 0
      ;;
    Invalid)
      echo "error: notarization rejected. See why with:" >&2
      echo "  xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
      rm -f "$ID_FILE"
      exit 1
      ;;
    *)
      echo "warn: submission $id has status '${status:-unknown}' — starting fresh." >&2
      rm -f "$ID_FILE"
      ;;
  esac
}

# Resume a previous run that was interrupted after submitting.
if [[ -f "$ID_FILE" && -f "$DMG_PATH" ]]; then
  echo "==> Found pending submission for $DMG_PATH — resuming (no rebuild)"
  finish_submission "$(cat "$ID_FILE")"
fi

IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' certificate found in keychain." >&2
  echo "Create one via Xcode → Settings → Accounts → Manage Certificates." >&2
  exit 1
fi
echo "Signing identity: $IDENTITY"

echo "==> Building release app"
fvm flutter build macos --release

echo "==> Signing Sparkle helpers (inside-out, hardened runtime)"
# Sparkle.framework embeds nested executables (Autoupdate, the Updater app, and
# on sandboxed apps XPC services) that Apple's notary service inspects on their
# own. The depth-1 loop below only signs the framework *wrapper*, so these must
# be signed first — otherwise notarization fails with "the executable does not
# have the hardened runtime enabled". Do NOT use `codesign --deep` for this;
# Sparkle's docs forbid it (it clobbers each component's own requirements).
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  sparkle_sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"; }
  # XPC services only exist for sandboxed apps (ClaudeBar is not), but sign them
  # if a future Sparkle build ships them. Glob over Versions/* to stay robust.
  for xpc in "$SPARKLE"/Versions/*/XPCServices/*.xpc; do
    [[ -e "$xpc" ]] && sparkle_sign "$xpc"
  done
  for helper in "$SPARKLE"/Versions/*/Autoupdate "$SPARKLE"/Versions/*/Updater.app; do
    [[ -e "$helper" ]] && sparkle_sign "$helper"
  done
  sparkle_sign "$SPARKLE"   # wrapper LAST so its seal covers the helpers above
fi

echo "==> Signing nested frameworks and dylibs"
while IFS= read -r -d '' item; do
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item"
done < <(find "$APP_PATH/Contents/Frameworks" -depth 1 \
           \( -name "*.framework" -o -name "*.dylib" \) -print0)

echo "==> Signing app bundle"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_PATH"
# Not --deep: deep-verify is tolerated but deep-sign (above) is the real hazard;
# a non-deep strict verify surfaces per-component problems honestly.
codesign --verify --strict --verbose=2 "$APP_PATH"

echo "==> Packaging DMG"
scripts/make_dmg.sh

echo "==> Signing DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG_PATH"

echo "==> Submitting to Apple notary service (usually 1-5 minutes)"
SUBMISSION_ID="$(xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" --output-format json \
  | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)"
if [[ -z "$SUBMISSION_ID" ]]; then
  echo "error: upload failed — no submission id returned." >&2
  exit 1
fi
echo "$SUBMISSION_ID" > "$ID_FILE"
finish_submission "$SUBMISSION_ID"

echo "error: unexpected submission state." >&2
exit 1

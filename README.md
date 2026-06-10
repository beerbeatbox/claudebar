# ClaudeBar

A lightweight **macOS menu-bar app** (built in Flutter) that shows your Claude
usage as a live percentage, with a clean popover for the full breakdown —
session (5h) + weekly (7d) windows, per-model weekly, plan badge, reset
countdowns, and manual/auto refresh.

It reads your **own** locally-stored Claude Code credentials (read-only) and
calls the official OAuth usage endpoint. It never logs in, scrapes, or writes
tokens back.

---

## Requirements & toolchain

- macOS 14+ (Apple Silicon or Intel)
- **FVM** pinned to Flutter **3.41.6** (`.fvmrc`) — same as the sibling
  projects. Run `fvm install` if the SDK isn't cached yet.
- A signed-in Claude Code on the same machine (credentials in the login
  Keychain or `~/.claude/.credentials.json`).

## Run & build (RPS scripts)

This project uses [`rps`](https://pub.dev/packages/rps) for task scripts (see
`scripts:` in `pubspec.yaml`):

```bash
rps pub get      # fvm flutter pub get
rps run          # fvm flutter run -d macos
rps analyze      # fvm flutter analyze
rps build        # fvm flutter build macos --release
rps dist         # rps build + package a drag-to-/Applications DMG
rps clean        # fvm flutter clean && pub get
```

Or directly: `fvm flutter run -d macos`.

### DMG installer

`rps dist` builds the release app and packages it as
`build/dist/ClaudeBar-<version>.dmg` — the classic installer window where you
drag the app icon onto the `/Applications` folder. For the styled window
(icon positions, drop link) install [`create-dmg`](https://github.com/create-dmg/create-dmg)
first:

```bash
brew install create-dmg
```

Without it the script falls back to plain `hdiutil`: the DMG still contains
the app plus an `/Applications` symlink, just with Finder's default layout.

### First-run Keychain prompt

On first launch macOS asks whether ClaudeBar may read the
`Claude Code-credentials` Keychain item. Click **Always Allow** to silence it
(Keychain Access → login → `Claude Code-credentials` → Access Control). This is
expected and required — without it the popover shows “Keychain access needed”.

---

## Architecture

```
lib/
├── main.dart                  # bootstrap: window_manager, tray, providers
├── app/
│   ├── popover_window.dart     # frameless popover: position under icon, hide on blur
│   ├── tray_controller.dart    # status-item title (%) + context menu
│   └── measure_size.dart       # size the window to its content
├── data/
│   ├── keychain.dart           # MethodChannel → Swift Keychain read
│   ├── credentials_reader.dart # file first, then Keychain; decode + scope check
│   └── usage_api.dart          # GET /api/oauth/usage → UsageSnapshot
├── models/                     # usage_window, usage_snapshot, credentials, usage_error
├── state/
│   └── usage_controller.dart   # Riverpod Notifier: refresh timer + snapshot/error
├── settings/
│   └── prefs.dart              # interval, menu-bar metric, launch-at-login
└── ui/                         # tokens, popover_panel, meter_row, plan_badge, settings_panel
```

State management is **Riverpod** (house style). One `UsageController` owns the
refresh timer and the latest `UsageSnapshot`/error; both the tray and the
popover listen to it.

The Keychain bridge is a `MethodChannel` (`claudebar/keychain`) handled in
`macos/Runner/MainFlutterWindow.swift` (`SecItemCopyMatching`, read-only).

`macos/Runner/Info.plist` sets `LSUIElement = true` (no Dock icon). The
entitlements have **App Sandbox OFF** for v1 (`com.apple.security.network.client`
only) so the app can read `~/.claude/*` and the foreign Keychain item — hence
it is distributed outside the Mac App Store.

---

## Verified API shape (the spec's VERIFY step)

Confirmed live against this machine — the parser is built to match:

**Credentials** (`Claude Code-credentials`, nested under `claudeAiOauth`):
`accessToken`, `refreshToken`, `expiresAt` (epoch **ms, int**), `scopes`
(list — must include `user:profile`), `subscriptionType` (e.g. `"max"`),
`rateLimitTier`.

**`GET https://api.anthropic.com/api/oauth/usage`** (headers `Authorization:
Bearer …`, `anthropic-beta: oauth-2025-04-20`) returns:

```jsonc
{
  "five_hour":        { "utilization": 24.0, "resets_at": "2026-06-09T18:29:59.741707+00:00" },
  "seven_day":        { "utilization": 12.0, "resets_at": "2026-06-13T19:00:00+00:00" },
  "seven_day_opus":   null,                      // per-model windows may be null
  "seven_day_sonnet": { "utilization": 0.0, "resets_at": null },
  "extra_usage":      { "is_enabled": false, "monthly_limit": null }
  // (plus extra seven_day_* buckets we ignore)
}
```

Key facts baked into the parser:
- `utilization` is **already 0–100** (not a 0–1 fraction) — we do **not**
  rescale, so a genuine `0.5` stays `0.5%`.
- `resets_at` is **ISO8601 with offset**, or `null`.
- Per-model windows can be `null`; those rows are simply hidden.

---

## Build status

- ✅ **Phase 0** — agent app, no Dock icon, static tray, clean quit.
- ✅ **Phase 1** — Keychain bridge + credentials reader + usage fetch/parse;
  live session/weekly % in the menu bar and context menu; all error states.
- ✅ **Phase 2** — styled frameless popover (meters, per-model rows, plan
  badge, reset countdowns, threshold colors), auto/manual refresh, settings
  (menu-bar metric, interval, launch-at-login), persisted across launches.
- ⬜ **Phase 3** (optional) — local JSONL token analytics, near-limit
  notifications, `$` cost via a maintained pricing map, notarized DMG.

## Tests

`fvm flutter test` covers credential parsing, the verified usage-payload
mapping (0–100 scale, ISO resets, null windows), the 401→expired mapping, and
reset-countdown formatting.

---

Personal tool. Credentials are read-only; nothing is transmitted anywhere
except the authenticated GET to `api.anthropic.com`.

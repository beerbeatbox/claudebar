#!/usr/bin/env bash
# Capture the evidence for a phantom input-source capsule sighting (the blue
# language badge flashing while you type in another app).
#
#   scripts/capture_focus_log.sh            # dump the last 30 min, then watch live
#   scripts/capture_focus_log.sh 120        # look back 120 min instead
#
# Why not just `log stream`: a stream only shows what happens AFTER you start
# it, and the capsule is intermittent — by the time you have a terminal open,
# the event you wanted is already gone. So this dumps the recent past FIRST
# (that is where the sighting you just had lives), then keeps watching, and
# tees everything to a file so nothing is lost to scrollback.
#
# Reading the result — the FocusSentinel lines (see MainFlutterWindow.swift)
# around a capsule's timestamp answer the only question that matters:
#   "APP ACTIVATED" / "window became key: …"  → ClaudeBar moved focus. Guilty;
#       the line names the window class and whether it was even visible.
#   only "input source changed -> …"          → something switched the keyboard
#       layout and it was not us; ClaudeBar never touched focus.
#   nothing at all near the timestamp          → ClaudeBar was not involved.
set -uo pipefail

MINUTES="${1:-30}"
SUBSYSTEM="one.beatbox.claudeUsageBar"
APP="/Applications/ClaudeBar.app"
OUT="$HOME/claudebar-focus-$(date +%Y%m%d-%H%M%S).log"

# The sentinel shipped in 1.6.1 (build 23). On anything older these logs simply
# do not exist, and an empty capture would look like "ClaudeBar is innocent"
# when it really means "ClaudeBar cannot answer" — so check loudly first.
if [[ -d "$APP" ]]; then
  BUILD="$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)"
  SHORT="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
  echo "Installed: ClaudeBar $SHORT (build $BUILD)"
  if [[ "$BUILD" =~ ^[0-9]+$ ]] && (( BUILD < 23 )); then
    echo "  !! This build predates the focus sentinel (needs 1.6.1 / build 23+)."
    echo "  !! Update first — until then this capture can only ever come back empty."
  fi
else
  echo "note: $APP not found; is ClaudeBar installed somewhere else?"
fi

# A running instance from BEFORE the update still has no sentinel in it, even
# once the new bundle is on disk. Compare what is running to what is installed.
if PID="$(pgrep -x ClaudeBar | head -1)"; then
  RUNNING_BUNDLE="$(ps -o comm= -p "$PID" | sed 's|/Contents/MacOS/ClaudeBar$||')"
  echo "Running:   pid $PID  ($RUNNING_BUNDLE)"
  if [[ "$RUNNING_BUNDLE" != "$APP" ]]; then
    echo "  !! The running copy is not the one in /Applications."
  fi
else
  echo "  !! ClaudeBar is not running — nothing can be logged."
fi

echo
echo "Writing to: $OUT"
echo "=== Past $MINUTES minutes (the sighting you already had) ==="

# `process` as well as `subsystem`: this also catches Sparkle's own logging,
# which happens inside our process under its own subsystem — exactly the thing
# the previous fix was about, so it is worth seeing if it ever speaks up again.
PRED="subsystem == \"$SUBSYSTEM\" OR process == \"ClaudeBar\""

log show --info --last "${MINUTES}m" --predicate "$PRED" 2>&1 | tee "$OUT"

echo | tee -a "$OUT"
echo "=== Live from $(date '+%H:%M:%S') — reproduce the capsule now, Ctrl-C when done ===" | tee -a "$OUT"
echo "(Note the wall-clock time the capsule appears; that timestamp is what to match.)"
echo

log stream --info --predicate "$PRED" 2>&1 | tee -a "$OUT"

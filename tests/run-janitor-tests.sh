#!/usr/bin/env bash
# Test suite for claude-dictate-janitor's stream-recorder sweep. Plain bash.
#
# The janitor matches recorders by process name, so the fakes are a script
# named pw-record that idles without writing: one whose reader has gone (the
# leak), one still being read (a healthy listener's), and one recording to a
# file with an unread stdout (push-to-talk). Only the first may die.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../claude-dictate-janitor"
[[ -f "$SCRIPT" ]] || { echo "script under test not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'pkill -f "$SANDBOX/bin/pw-record" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/runtime" "$SANDBOX/bin"
# the sleep's stdout is redirected so only the recorder itself holds the pipe
printf '#!/bin/bash\nwhile :; do sleep 1 >/dev/null; done\n' > "$SANDBOX/bin/pw-record"
chmod +x "$SANDBOX/bin/pw-record"
rec() { pgrep -f "$SANDBOX/bin/pw-record $1\$"; }

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; fail=$((fail + 1)); }

echo "# stream recorders"
exec 3< <("$SANDBOX/bin/pw-record" --target a - | true)
exec 3<&-
exec 4< <("$SANDBOX/bin/pw-record" --target b - | cat)
exec 5< <("$SANDBOX/bin/pw-record" --target c "$SANDBOX/rec.wav" | true)
exec 5<&-
sleep 0.5
orphan=$(rec "--target a -") healthy=$(rec "--target b -") ptt=$(rec "--target c $SANDBOX/rec.wav")

out=$(XDG_RUNTIME_DIR="$SANDBOX/runtime" "$SCRIPT")
sleep 0.3
if [[ -n "$orphan" ]] && ! kill -0 "$orphan" 2>/dev/null; then ok "an unread recorder is killed"
else no "an unread recorder is killed" "pid=$orphan"; fi
if grep -q "orphaned stream recorder $orphan" <<<"$out"; then ok "and the kill is logged"
else no "and the kill is logged" "got: $out"; fi
if [[ -n "$healthy" ]] && kill -0 "$healthy" 2>/dev/null; then ok "a recorder with a reader is left alone"
else no "a recorder with a reader is left alone" "pid=$healthy"; fi
if [[ -n "$ptt" ]] && kill -0 "$ptt" 2>/dev/null; then ok "a push-to-talk recorder is left alone"
else no "a push-to-talk recorder is left alone" "pid=$ptt"; fi
exec 4<&-

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))

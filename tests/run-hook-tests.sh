#!/usr/bin/env bash
# Test suite for claude-speak-hook. Plain bash, no frameworks.
#
# The hook resolves its claude-speak sibling by readlink-of-$0, so the suite
# copies it into a sandbox and plants a fake sibling there — every payload is
# then driven end to end (gate → parse → dedup → speak/stop) with the fakes
# recording what was spoken and what was silenced.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOOK="$TESTS_DIR/../claude-speak-hook"
[[ -f "$REAL_HOOK" ]] || { echo "script under test not found: $REAL_HOOK" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

FAKEBIN="$SANDBOX/bin"
RUNTIME="$SANDBOX/runtime"
CONFHOME="$SANDBOX/config"
SPOKE="$SANDBOX/spoke.txt"      # what the fake claude-speak was asked to say
STOPS="$SANDBOX/stops.txt"      # each --stop it received
mkdir -p "$FAKEBIN" "$RUNTIME" "$CONFHOME"

HOOK="$SANDBOX/claude-speak-hook"
cp "$REAL_HOOK" "$HOOK"; chmod +x "$HOOK"

# fake sibling: records --stop calls and spoken text
cat > "$SANDBOX/claude-speak" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--stop" ]]; then echo stop >> "$STOPS"; exit 0; fi
cat >> "$SPOKE"; printf '\n' >> "$SPOKE"
EOF
chmod +x "$SANDBOX/claude-speak"

# fake tmux: reports whatever session the test claims the pane belongs to
cat > "$FAKEBIN/tmux" <<'EOF'
#!/bin/sh
[ -n "$FAKE_SESSION" ] || exit 1
echo "$FAKE_SESSION"
EOF
chmod +x "$FAKEBIN/tmux"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }

# fire(json, [env overrides...]) — run the hook on a payload
fire() {
    local json="$1"; shift
    printf '%s' "$json" | env -i \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        HOME="$SANDBOX" \
        XDG_RUNTIME_DIR="$RUNTIME" \
        XDG_CONFIG_HOME="$CONFHOME" \
        TMUX_PANE="%1" \
        FAKE_SESSION="claude" \
        "$@" \
        bash "$HOOK" >/dev/null 2>&1
}

spoke()  { cat "$SPOKE" 2>/dev/null; }
flat()   { tr -s '\n' < "$SPOKE" 2>/dev/null; }
stops()  { wc -l < "$STOPS" 2>/dev/null || echo 0; }
reset()  { : > "$SPOKE"; : > "$STOPS"; rm -rf "$RUNTIME/claude-dictate"; }

md() { # md(session, msgid, index, final, text) — a MessageDisplay payload
    jq -nc --arg s "$1" --arg m "$2" --argjson i "$3" --argjson f "$4" --arg d "$5" \
       '{hook_event_name:"MessageDisplay", session_id:$s, message_id:$m,
         index:$i, final:$f, delta:$d}'
}
stop_payload() { # stop_payload(session, text)
    jq -nc --arg s "$1" --arg t "$2" \
       '{hook_event_name:"Stop", session_id:$s, last_assistant_message:$t}'
}

echo "# session gating"
reset
fire "$(stop_payload s1 'should not speak')" TMUX_PANE=
eq "no tmux pane stays silent" "$(spoke)" ""
fire "$(stop_payload s1 'should not speak')" FAKE_SESSION=workterm
eq "wrong tmux session stays silent" "$(spoke)" ""
fire '{"hook_event_name":"UserPromptSubmit"}' FAKE_SESSION=workterm
eq "prompt in another session does NOT stop speech" "$(stops)" "0"
fire '{"hook_event_name":"UserPromptSubmit"}'
eq "prompt in the dictation session stops speech" "$(stops)" "1"

echo "# focus gating"
# With claude-roster in play the focused pane is the only audible one, whatever
# session it sits in — the session gate (and its tmux call) is bypassed.
reset
mkdir -p "$RUNTIME/claude-dictate"
printf '%%1' > "$RUNTIME/claude-dictate/focus-pane"
fire "$(stop_payload f1 'focused pane speaks')" FAKE_SESSION=whatever
eq "the focused pane speaks regardless of session" "$(spoke)" "focused pane speaks"

printf '%%2' > "$RUNTIME/claude-dictate/focus-pane"
fire "$(stop_payload f2 'should not speak')"
eq "an unfocused pane stays silent" "$(spoke)" "focused pane speaks"
fire '{"hook_event_name":"UserPromptSubmit"}'
eq "an unfocused pane cannot stop speech" "$(stops)" "0"

printf '%%1' > "$RUNTIME/claude-dictate/focus-pane"
fire '{"hook_event_name":"UserPromptSubmit"}'
eq "the focused pane stops speech" "$(stops)" "1"

rm -f "$RUNTIME/claude-dictate/focus-pane"
fire "$(stop_payload f3 'back to session gating')"
eq "no focus file falls back to the session gate" \
   "$(flat)" $'focused pane speaks\nback to session gating'

echo "# MessageDisplay"
# A message arrives as a RUN of deltas sharing one message_id, each carrying
# only its own new text, with only the last marked final. The suite used to
# assert that a non-final delta stays silent — which is precisely how a long
# reply came out as its closing paragraph and nothing else.
reset
fire "$(md s2 m1 0 true 'first message')"
eq "a lone final delta is spoken" "$(spoke)" "first message"
fire "$(md s2 m1 0 true 'first message')"
eq "a redelivered index is not spoken twice" "$(spoke)" "first message"

reset
fire "$(md s7 m1 0 false $'para one.\n\n')"
fire "$(md s7 m1 1 false $'para two.\n\n')"
fire "$(md s7 m1 2 true  'para three.')"
eq "every delta of a message is spoken, in order" \
   "$(flat)" $'para one.\npara two.\npara three.'

reset
fire "$(md s8 m1 0 false 'a sentence with no ')"
fire "$(md s8 m1 1 true  'paragraph break in it')"
eq "a delta mid-paragraph is held and joined, not dropped" \
   "$(flat)" "a sentence with no paragraph break in it"

# claude-speak strips a code block by matching a ``` PAIR, so a buffer flushed
# with an odd fence count would read the code out loud.
reset
fire "$(md s9 m1 0 false $'here it is:\n\n')"
fire "$(md s9 m1 1 false $'```\nrm -rf /\n\n')"
eq "an open code fence holds the flush" "$(flat)" "here it is:"
fire "$(md s9 m1 2 true $'```\n\nthat was it.')"
eq "the fenced run is released once the pair closes" \
   "$(flat)" $'here it is:\n```\nrm -rf /\n```\nthat was it.'

# Two deltas can be in flight at once; order must come from the index.
reset
fire "$(md sA m1 1 false $'second.\n\n')"
eq "a delta arriving early is held for its predecessor" "$(flat)" ""
fire "$(md sA m1 0 false $'first.\n\n')"
eq "the run is reassembled in index order" "$(flat)" $'first.\nsecond.'

# A hook that failed or timed out leaves a hole. The tail must not be lost.
reset
fire "$(md sB m1 0 false $'opening.\n\n')"
fire "$(md sB m1 2 true  'closing.')"
eq "final salvages an index stranded behind a gap" "$(flat)" $'opening.\nclosing.'

# The dedup regression that motivated the rewrite of the ledger: identical
# text under a NEW message id is a new reply and must be spoken.
reset
fire "$(md s2 m3 0 true 'Done.')"
fire "$(md s2 m4 0 true 'Done.')"
eq "an identical later reply is still spoken" "$(flat)" $'Done.\nDone.'

echo "# Stop vs MessageDisplay"
fire "$(stop_payload s2 'Done.')"
eq "Stop is silent when MessageDisplay already spoke this session" \
   "$(flat)" $'Done.\nDone.'

reset
fire "$(stop_payload s3 'end of turn summary')"
eq "Stop speaks when MessageDisplay never fired" "$(spoke)" "end of turn summary"
fire "$(stop_payload s3 'end of turn summary')"
eq "a double Stop does not repeat itself" "$(spoke)" "end of turn summary"

reset
fire "$(jq -nc '{hook_event_name:"Stop", session_id:"s4",
                 last_assistant_message:"quiet", stop_hook_active:true}')"
eq "stop_hook_active suppresses the repeat" "$(spoke)" ""

echo "# legacy payloads (the TSV field-shift regression)"
reset
# No hook_event_name at all — the empty leading field used to shift every
# later field left and the fallback branch could never fire.
fire "$(jq -nc '{session_id:"s5", last_assistant_message:"legacy stop text"}')"
eq "a payload with no event name still speaks via the fallback" \
   "$(spoke)" "legacy stop text"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

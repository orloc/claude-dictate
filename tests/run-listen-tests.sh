#!/usr/bin/env bash
# Test suite for claude-listen. Plain bash, no frameworks.
#
# The script's BASH_SOURCE guard lets these source it and call the grammar
# directly. The state-machine tests go one step further and replace transcribe/
# tone/speak/send_buffer after sourcing, so a whole conversation can be driven
# without a microphone, whisper, or a tmux session — and so the tests can assert
# what was NOT done (the help command must never dictate).

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../claude-listen"
[[ -f "$SCRIPT" ]] || { echo "script under test not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Keep the user's real config out of the run; the defaults are what we assert.
export XDG_CONFIG_HOME="$SANDBOX/config"
export XDG_RUNTIME_DIR="$SANDBOX/runtime"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"

# shellcheck source=/dev/null
. "$SCRIPT"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }

# --- normalization ----------------------------------------------------------
echo "# normalize"
eq "lowercases and drops punctuation" "$(normalize <<<'Skylark, Come In!')" "skylark come in"
eq "collapses runs of whitespace"     "$(normalize <<<'  skylark   out  ')" "skylark out"
eq "strips a trailing period"         "$(normalize <<<'skylark out.')"      "skylark out"

# --- standalone commands ----------------------------------------------------
echo "# standalone commands"
try_standalone() { standalone_command "$(normalize <<<"$1")" || printf '(none)'; }

eq "come in opens"                 "$(try_standalone 'Skylark, come in.')"    "open"
eq "help is recognized"            "$(try_standalone 'skylark help')"         "help"
eq "radio check is recognized"     "$(try_standalone 'Skylark, radio check')" "status"
eq "silence is recognized"         "$(try_standalone 'skylark silence')"      "hush"
eq "an alias spelling still works" "$(try_standalone 'Sky lark, come in')"    "open"

# The whole-utterance rule is the thing that makes the protocol safe: these are
# all sentences a person says while describing the system.
eq "embedded phrase does not fire"    "$(try_standalone 'then skylark comes in later')"          "(none)"
eq "phrase with a prefix does not fire" "$(try_standalone 'I said skylark come in')"             "(none)"
eq "phrase with a suffix does not fire" "$(try_standalone 'skylark come in to the room')"        "(none)"
eq "callsign alone does not fire"     "$(try_standalone 'skylark')"                              "(none)"
eq "proword alone does not fire"      "$(try_standalone 'come in')"                              "(none)"
eq "wrong callsign does not fire"     "$(try_standalone 'seagull come in')"                      "(none)"

# --- terminal commands ------------------------------------------------------
echo "# terminal commands"
try_terminal() { terminal_command "$(normalize <<<"$1")" || printf '(none)'; }

eq "out closes and returns the remainder" \
   "$(try_terminal 'fix the parser please Skylark, out.')" "$(printf 'close\tfix the parser please')"
eq "disregard cancels" \
   "$(try_terminal 'scratch that Skylark disregard')"      "$(printf 'cancel\tscratch that')"
eq "a bare close has an empty remainder" \
   "$(try_terminal 'skylark out')"                         "$(printf 'close\t')"

# Ending a technical sentence with these words is entirely plausible, which is
# why the callsign has to be attached.
eq "a sentence ending in out does not close"     "$(try_terminal 'move the loop out')"      "(none)"
eq "a sentence ending in disregard does not fire" "$(try_terminal 'the parser will disregard')" "(none)"
eq "callsign mid-sentence does not close"        "$(try_terminal 'skylark out of the way now')" "(none)"

# --- state machine ----------------------------------------------------------
echo "# state machine"
# Replace every side effect with a recorder, so a session can be driven and,
# more importantly, so we can assert nothing was dictated.
SPOKEN=""; SENT=""; TONES=""
NEXT_TEXT=""
transcribe()  { printf '%s' "$NEXT_TEXT"; }
tone()        { TONES="${TONES:+$TONES }$1"; }
speak()       { SPOKEN="${SPOKEN:+$SPOKEN | }$1"; }
send_buffer() { SENT="${SENT:+$SENT | }$1"; }
log()         { :; }

say() { NEXT_TEXT="$1"; handle "$SANDBOX/nonexistent.wav"; }

STATE=standby; BUFFER=""; SENT=""; TONES=""
say "hey can you look at the parser for me"
eq "standby ignores ordinary speech"   "$STATE" "standby"
eq "standby dictates nothing"          "$SENT"  ""

say "Skylark, come in."
eq "come in opens the mic"             "$STATE" "transmitting"

say "look at the dictate script"
say "and tell me if the parser is right"
eq "speech accumulates while open"     "$BUFFER" "look at the dictate script and tell me if the parser is right"
eq "nothing is sent mid-transmission"  "$SENT"   ""

say "then fix it Skylark, out."
eq "out closes the mic"                "$STATE" "standby"
eq "out sends buffer plus remainder"   "$SENT" \
   "look at the dictate script and tell me if the parser is right then fix it"

# discard path
STATE=standby; BUFFER=""; SENT=""
say "skylark come in"
say "this is all wrong"
say "skylark disregard"
eq "disregard returns to standby"      "$STATE" "standby"
eq "disregard sends nothing"           "$SENT"  ""
eq "disregard clears the buffer"       "$BUFFER" ""

# the help command, which must never reach the dictation path
STATE=standby; BUFFER=""; SENT=""; SPOKEN=""
say "skylark help"
eq "help stays in standby"             "$STATE"  "standby"
eq "help dictates nothing"             "$SENT"   ""
eq "help leaves the buffer alone"      "$BUFFER" ""
if grep -qF "To open the mic" <<<"$SPOKEN"; then ok "help speaks the protocol"
else no "help speaks the protocol" "spoke: $SPOKEN"; fi
if grep -qF "$CALLSIGN" <<<"$SPOKEN"; then ok "help names the configured callsign"
else no "help names the configured callsign" "spoke: $SPOKEN"; fi

# a command word said while transmitting is dictation, not a command
STATE=standby; BUFFER=""; SENT=""; SPOKEN=""
say "skylark come in"
say "skylark help"
eq "help mid-transmission is dictated, not run" "$BUFFER" "skylark help"
eq "help mid-transmission speaks nothing"       "$SPOKEN" ""

# a close command with the mic already shut is an error, not a send
STATE=standby; BUFFER=""; SENT=""; TONES=""
say "skylark out"
eq "closing an already-closed mic sends nothing" "$SENT" ""
if grep -qw err <<<"$TONES"; then ok "closing an already-closed mic errors"
else no "closing an already-closed mic errors" "tones: $TONES"; fi

# the transmission timeout must send rather than lose the buffer
STATE=transmitting; BUFFER="a long thought"; SENT=""; TX_START=$SECONDS; MAX_TX=0
check_timeout
eq "timeout closes the mic"  "$STATE" "standby"
eq "timeout sends the buffer" "$SENT" "a long thought"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

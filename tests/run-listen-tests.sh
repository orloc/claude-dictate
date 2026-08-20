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
# A real recorder dies of SIGPIPE when its segmenter goes; the fake one never
# writes, so it must be reaped by path or it lingers for its full sleep.
trap 'pkill -f "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT

# A set TMUX would let anything that reaches a real tmux client target the
# server hosting this very test run (see run-tests.sh for the incident).
unset TMUX TMUX_PANE

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

eq "come in opens"                 "$(try_standalone 'Skylark, come in.')"    $'skylark\topen'
eq "help is recognized"            "$(try_standalone 'skylark help')"         $'skylark\thelp'
eq "radio check is recognized"     "$(try_standalone 'Skylark, radio check')" $'skylark\tstatus'
eq "silence is recognized"         "$(try_standalone 'skylark silence')"      $'skylark\thush'
eq "an alias spelling still works" "$(try_standalone 'Sky lark, come in')"    $'skylark\topen'

# The whole-utterance rule is the thing that makes the protocol safe: these are
# all sentences a person says while describing the system.
eq "embedded phrase does not fire"    "$(try_standalone 'then skylark comes in later')"          "(none)"
eq "phrase with a prefix does not fire" "$(try_standalone 'I said skylark come in')"             "(none)"
eq "phrase with a suffix does not fire" "$(try_standalone 'skylark come in to the room')"        "(none)"
eq "callsign alone does not fire"     "$(try_standalone 'skylark')"                              "(none)"
eq "proword alone does not fire"      "$(try_standalone 'come in')"                              "(none)"
eq "wrong callsign does not fire"     "$(try_standalone 'seagull come in')"                      "(none)"

# --- instance and management grammar -----------------------------------------
echo "# instance and management grammar"
# Pool names take the callsign's position; the callsign takes the management
# verbs; both resolve whisper's misspellings to canonical names.
eq "an instance name opens"          "$(try_standalone 'Alpha, come in.')"     $'alpha\topen'
eq "an instance alias resolves"      "$(try_standalone 'Charley, come in')"    $'charlie\topen'
eq "focus is an instance command"    "$(try_standalone 'bravo focus')"         $'bravo\tfocus'
eq "focus on the callsign is not"    "$(try_standalone 'skylark focus')"       "(none)"
eq "spawn is recognized"             "$(try_standalone 'Skylark, spawn.')"     $'skylark\tspawn'
eq "list is recognized"              "$(try_standalone 'skylark list')"        $'skylark\tlist'
eq "reap is recognized"              "$(try_standalone 'skylark reap')"        $'skylark\treap'
eq "status is recognized"            "$(try_standalone 'skylark status')"      $'skylark\tstatus'
eq "spawn on an instance is not"     "$(try_standalone 'alpha spawn')"         "(none)"
eq "kill carries its argument"       "$(try_standalone 'Skylark, kill charlie')" $'skylark\tkill\tcharlie'
eq "kill resolves an alias argument" "$(try_standalone 'skylark kill charley')"  $'skylark\tkill\tcharlie'
eq "rename carries both arguments"   "$(try_standalone 'skylark rename bravo to alpha')" \
                                     $'skylark\trename\tbravo\talpha'
eq "rename resolves alias arguments" "$(try_standalone 'skylark rename brava to alfa')" \
                                     $'skylark\trename\tbravo\talpha'
eq "rename without to does not fire" "$(try_standalone 'skylark rename bravo alpha')"   "(none)"
eq "kill on an instance is not a command" "$(try_standalone 'alpha kill bravo')"        "(none)"
eq "kill inside prose does not fire" "$(try_standalone 'and then skylark kill charlie happened')" "(none)"
eq "instance name alone does not fire" "$(try_standalone 'alpha')"                      "(none)"
eq "instance phrase with a suffix does not fire" "$(try_standalone 'alpha come in here')" "(none)"

# --- verb-first word order ---------------------------------------------------
echo "# verb-first word order"
# A directional proword takes its target on either side. The target is still
# required, and still has to be a name.
eq "focus takes the name first"      "$(try_standalone 'focus bravo')"         $'bravo\tfocus'
eq "focus takes the name last"       "$(try_standalone 'bravo focus')"         $'bravo\tfocus'
eq "verb-first resolves an alias"    "$(try_standalone 'Focus Charley.')"      $'charlie\tfocus'
eq "come in reverses too"            "$(try_standalone 'come in alpha')"       $'alpha\topen'
eq "silence reverses too"            "$(try_standalone 'silence alpha')"       $'alpha\thush'
eq "verb-first needs a real name"    "$(try_standalone 'focus the parser')"    "(none)"
eq "verb-first needs any name"       "$(try_standalone 'focus')"               "(none)"
eq "verb-first rejects an unknown name" "$(try_standalone 'focus seagull')"    "(none)"
eq "verb-first does not fire in prose" "$(try_standalone 'we should focus alpha first')" "(none)"
eq "verb-first focus on the callsign is still not a command" \
                                     "$(try_standalone 'focus skylark')"       "(none)"
# Management verbs keep their fixed shape — they are not directional.
eq "verb-first does not reach spawn" "$(try_standalone 'spawn skylark')"       "(none)"
eq "verb-first does not reach list"  "$(try_standalone 'list skylark')"        "(none)"
# The closing commands stay one-way, which is what keeps them out of prose.
eq "out does not reverse"            "$(try_standalone 'out bravo')"           "(none)"
eq "disregard does not reverse"      "$(try_standalone 'disregard bravo')"     "(none)"

# --- terminal commands ------------------------------------------------------
echo "# terminal commands"
try_terminal() { terminal_command "$(normalize <<<"$1")" || printf '(none)'; }

eq "out closes and returns the remainder" \
   "$(try_terminal 'fix the parser please Skylark, out.')" "$(printf 'skylark\tclose\tfix the parser please')"
eq "disregard cancels" \
   "$(try_terminal 'scratch that Skylark disregard')"      "$(printf 'skylark\tcancel\tscratch that')"
eq "a bare close has an empty remainder" \
   "$(try_terminal 'skylark out')"                         "$(printf 'skylark\tclose\t')"
eq "an instance close carries its name" \
   "$(try_terminal 'run the tests alpha out')"             "$(printf 'alpha\tclose\trun the tests')"
eq "an instance alias close resolves" \
   "$(try_terminal 'run the tests charley out')"           "$(printf 'charlie\tclose\trun the tests')"

# Ending a technical sentence with these words is entirely plausible, which is
# why the callsign has to be attached.
eq "a sentence ending in out does not close"     "$(try_terminal 'move the loop out')"      "(none)"
eq "a sentence ending in disregard does not fire" "$(try_terminal 'the parser will disregard')" "(none)"
eq "callsign mid-sentence does not close"        "$(try_terminal 'skylark out of the way now')" "(none)"

# --- state machine ----------------------------------------------------------
echo "# state machine"
# Replace every side effect with a recorder, so a session can be driven and,
# more importantly, so we can assert nothing was dictated.
SPOKEN=""; SENT=""; TONES=""; NOTES=""
NEXT_TEXT=""
transcribe()  { printf '%s' "$NEXT_TEXT"; }
tone()        { TONES="${TONES:+$TONES }$1"; }
speak()       { SPOKEN="${SPOKEN:+$SPOKEN | }$1"; }
send_buffer() { SENT="${SENT:+$SENT | }$1"; SENT_TO="$TX_TARGET"; }
notify()      { NOTES="${NOTES:+$NOTES | }$3"; }   # also keeps real popups out of a test run
log()         { :; }

# Fake roster: FAKE_ROSTER holds `claude-roster list` output; ROSTER_CALLS
# records every subcommand, so a test can assert what the voice layer asked
# the substrate to do without a tmux server in the room.
FAKE_ROSTER=""; ROSTER_CALLS=""
roster() {
    ROSTER_CALLS="${ROSTER_CALLS:+$ROSTER_CALLS }$*"
    case "$1" in
        list)   printf '%s' "$FAKE_ROSTER" ;;
        pane|focus|kill)
                awk -F'\t' -v n="$2" '$1 == n { print $2; found=1 } END { exit !found }' \
                    <<<"$FAKE_ROSTER" >/dev/null || return 1 ;;
        rename) grep -q "^$2	" <<<"$FAKE_ROSTER" || return 1 ;;
        spawn)  printf 'alpha\t%%9\n' ;;
        reap)   printf '%s' "${FAKE_REAPED:-}" ;;
    esac
}

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

# --- named instances ----------------------------------------------------------
echo "# named instances"
# With a roster up, the instance name is the callsign and the callsign is
# management-only. Roster effects are asserted through the fake's call log.
FAKE_ROSTER=$'alpha\t%1\tfocused\nbravo\t%2\t-'

STATE=standby; BUFFER=""; SENT=""; SENT_TO=""; TONES=""; ROSTER_CALLS=""; TX_TARGET=""
say "Alpha, come in."
eq "an instance opens the mic"        "$STATE" "transmitting"
eq "the transmission is owned by it"  "$TX_TARGET" "alpha"
if grep -q "focus alpha" <<<"$ROSTER_CALLS"; then ok "opening focuses the instance"
else no "opening focuses the instance" "calls: $ROSTER_CALLS"; fi

say "run the test suite"
say "bravo out"
eq "a close under the wrong name does not send"  "$SENT" ""
eq "the wrong-name close keeps transmitting"     "$STATE" "transmitting"
if grep -qw err <<<"$TONES"; then ok "the wrong-name close sounds the error tone"
else no "the wrong-name close sounds the error tone" "tones: $TONES"; fi

say "alpha out"
eq "the right name closes and sends"      "$SENT" "run the test suite"
eq "the send is routed to the instance"   "$SENT_TO" "alpha"
eq "closing clears the target"            "$TX_TARGET" ""

# the callsign is refused as a dictation channel while instances are up
STATE=standby; BUFFER=""; SENT=""; TONES=""
say "skylark come in"
eq "the callsign cannot open with instances up" "$STATE" "standby"
if grep -qw err <<<"$TONES"; then ok "the refused open sounds the error tone"
else no "the refused open sounds the error tone" "tones: $TONES"; fi

# an instance that was never spawned cannot open the mic
STATE=standby; TONES=""; NOTES=""
say "delta, come in"
eq "an unknown instance cannot open"   "$STATE" "standby"
if grep -qF "no instance delta" <<<"$NOTES"; then ok "the refusal names the instance"
else no "the refusal names the instance" "notes: $NOTES"; fi

# management commands
STATE=standby; SPOKEN=""; ROSTER_CALLS=""
say "skylark spawn"
if grep -qF "alpha up." <<<"$SPOKEN"; then ok "spawn speaks the new name"
else no "spawn speaks the new name" "spoke: $SPOKEN"; fi

SPOKEN=""
say "skylark list"
eq "list speaks the roster" "$SPOKEN" "2. alpha, focused. bravo."

SPOKEN=""
say "skylark status"
eq "status includes the roster" "$SPOKEN" "Standing by. 2. alpha, focused. bravo."

SPOKEN=""; ROSTER_CALLS=""
say "skylark kill bravo"
if grep -qF "bravo down." <<<"$SPOKEN"; then ok "kill speaks the takedown"
else no "kill speaks the takedown" "spoke: $SPOKEN"; fi
if grep -q "kill bravo" <<<"$ROSTER_CALLS"; then ok "kill reaches the roster"
else no "kill reaches the roster" "calls: $ROSTER_CALLS"; fi

TONES=""; SPOKEN=""
say "skylark kill charlie"
eq "killing an unknown instance speaks nothing" "$SPOKEN" ""
if grep -qw err <<<"$TONES"; then ok "killing an unknown instance errors"
else no "killing an unknown instance errors" "tones: $TONES"; fi

SPOKEN=""
say "skylark rename bravo to charlie"
if grep -qF "bravo is now charlie." <<<"$SPOKEN"; then ok "rename speaks the change"
else no "rename speaks the change" "spoke: $SPOKEN"; fi

SPOKEN=""; ROSTER_CALLS=""
say "bravo focus"
if grep -q "focus bravo" <<<"$ROSTER_CALLS"; then ok "focus reaches the roster"
else no "focus reaches the roster" "calls: $ROSTER_CALLS"; fi

SPOKEN=""; FAKE_REAPED=$'charlie\n'
say "skylark reap"
if grep -qF "Reaped charlie." <<<"$SPOKEN"; then ok "reap names the dropped"
else no "reap names the dropped" "spoke: $SPOKEN"; fi
FAKE_REAPED=""; SPOKEN=""
say "skylark reap"
if grep -qF "Roster clean." <<<"$SPOKEN"; then ok "a clean reap says so"
else no "a clean reap says so" "spoke: $SPOKEN"; fi

# mid-transmission, management words are dictation like everything else
STATE=standby; BUFFER=""; SENT=""; SPOKEN=""
say "alpha come in"
say "skylark kill bravo"
eq "management inside a transmission is dictated" "$BUFFER" "skylark kill bravo"
eq "management inside a transmission speaks nothing" "$SPOKEN" ""
say "alpha disregard"

FAKE_ROSTER=""   # back to classic single-pane mode for the sections below

# --- desktop notifications --------------------------------------------------
# The mic state has to be visible without listening for a tone, so the open /
# building / sent transitions each say something.
echo "# notifications"
STATE=standby; BUFFER=""; SENT=""; NOTES=""
say "skylark come in"
if grep -qF "mic open" <<<"$NOTES"; then ok "opening the mic notifies"
else no "opening the mic notifies" "notes: $NOTES"; fi

NOTES=""
say "check the parser"
if grep -qF "check the parser" <<<"$NOTES"; then ok "notification echoes the transmission as it builds"
else no "notification echoes the transmission as it builds" "notes: $NOTES"; fi

NOTES=""
say "skylark disregard"
if grep -qF "discarded" <<<"$NOTES"; then ok "discarding notifies"
else no "discarding notifies" "notes: $NOTES"; fi

NOTES=""
say "hey what about the parser"
eq "standby speech notifies nothing" "$NOTES" ""

# --- listener liveness ------------------------------------------------------
# A pidfile is a claim, not proof: a crashed listener leaves one behind, and a
# recycled pid would otherwise make --toggle try to stop a stranger's process.
echo "# listener liveness"
mkdir -p "$(dirname "$PIDFILE")"

rm -f "$PIDFILE"
listener_pid >/dev/null && no "no pidfile means not running" || ok "no pidfile means not running"

echo "not-a-pid" > "$PIDFILE"
listener_pid >/dev/null && no "garbage pidfile means not running" || ok "garbage pidfile means not running"

# a pid that has certainly exited
sleep 0 & dead=$!; wait "$dead" 2>/dev/null
echo "$dead" > "$PIDFILE"
listener_pid >/dev/null && no "dead pid means not running" || ok "dead pid means not running"

sleep 30 & live=$!
echo "$live" > "$PIDFILE"
eq "a live pid is reported" "$(listener_pid)" "$live"
kill "$live" 2>/dev/null
rm -f "$PIDFILE"

# --- singleton ----------------------------------------------------------------
# Two live listeners share the mic and each cleanup destroys the other, so a
# second --run must be refused while the first holds the lock. Driven with a
# real background instance on fake binaries — no mic, whisper, or tmux needed.
echo "# singleton"
FB="$SANDBOX/bin"; mkdir -p "$FB"
printf '#!/bin/sh\nexit 0\n' > "$FB/fake-whisper"
# Streams like the real recorder, so it dies of SIGPIPE when its segmenter is
# killed instead of lingering as an orphan the suite has to hunt down.
printf '#!/bin/sh\nexec cat /dev/zero\n' > "$FB/fake-recorder"
printf '#!/bin/sh\nexit 0\n' > "$FB/notify-send"
chmod +x "$FB"/*
: > "$SANDBOX/model.bin"

run_bg_listener() {
    env -i PATH="$FB:/usr/bin:/bin" HOME="$SANDBOX" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        DICTATE_WHISPER="$FB/fake-whisper" DICTATE_MODEL="$SANDBOX/model.bin" \
        DICTATE_RECORDER="$FB/fake-recorder" \
        bash "$SCRIPT" --run
}

run_bg_listener >/dev/null 2>&1 &
first=$!
sleep 2
if kill -0 "$first" 2>/dev/null; then ok "first listener is running"
else no "first listener is running"; fi

second_out=$(run_bg_listener 2>&1); second_st=$?
eq "a second listener is refused"      "$second_st" "1"
if grep -q "already running" <<<"$second_out"; then ok "the refusal says why"
else no "the refusal says why" "got: $second_out"; fi

if kill -0 "$first" 2>/dev/null; then ok "the refusal does not damage the running one"
else no "the refusal does not damage the running one"; fi

# $first is the wrapper subshell; the listener's own pid is in its pidfile.
lpid=$(cat "$XDG_RUNTIME_DIR/claude-dictate/listen.pid" 2>/dev/null)
[[ -n "$lpid" ]] && kill -TERM "$lpid" 2>/dev/null
kill -TERM "$first" 2>/dev/null; wait "$first" 2>/dev/null
sleep 1
third_out=$(timeout 3 bash -c '
    env -i PATH="'"$FB"':/usr/bin:/bin" HOME="'"$SANDBOX"'" \
        XDG_RUNTIME_DIR="'"$XDG_RUNTIME_DIR"'" XDG_CONFIG_HOME="'"$XDG_CONFIG_HOME"'" \
        DICTATE_WHISPER="'"$FB/fake-whisper"'" DICTATE_MODEL="'"$SANDBOX/model.bin"'" \
        DICTATE_RECORDER="'"$FB/fake-recorder"'" \
        bash "'"$SCRIPT"'" --run 2>&1 & pid=$!
    sleep 2; kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null' )
if grep -q "listening" <<<"$third_out"; then ok "the lock is released when the holder dies"
else no "the lock is released when the holder dies" "got: $third_out"; fi

# a recorder that isn't installed is refused up front, not respawn-looped
missing_out=$(env -i PATH="$FB:/usr/bin:/bin" HOME="$SANDBOX" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DICTATE_WHISPER="$FB/fake-whisper" DICTATE_MODEL="$SANDBOX/model.bin" \
    DICTATE_RECORDER="no-such-recorder --flags" \
    bash "$SCRIPT" --run 2>&1); missing_st=$?
eq "a missing recorder is refused at startup" "$missing_st" "1"
if grep -q "recorder not found" <<<"$missing_out"; then ok "the recorder refusal says why"
else no "the recorder refusal says why" "got: $missing_out"; fi

# --- segmenter: ambient step ---------------------------------------------------
# Field failure: the noise floor only learned from frames it already considered
# quiet, so a step-up in ambient noise (wireless hiss, a fan) made EVERY frame
# read as speech and the mic stuck open until max-ms glued a minute of commands
# into one rejected utterance. With the fix the floor climbs 1 dB/s on loud
# frames too, so segments must keep closing after the step.
echo "# segmenter"
SEGOUT="$SANDBOX/seg"; mkdir -p "$SEGOUT"
utts=$(python3 - <<'PY' | timeout 15 python3 "$TESTS_DIR/../listen-segmenter.py" --outdir "$SEGOUT" 2>/dev/null | wc -l
import math, struct, sys
out, RATE = sys.stdout.buffer, 16000
def block(amp, secs, freq=200):
    for i in range(int(RATE * secs)):
        out.write(struct.pack('<h', int(amp * math.sin(2*math.pi*freq*i/RATE))))
block(50, 2)      # establish a quiet floor (~ -59 dBFS)
block(260, 5)     # ambient steps up ~14 dB — just past the 12 dB margin
block(8000, 0.6)  # a spoken command
block(260, 2)     # back to the new ambient, so the command can close
PY
)
if (( utts >= 1 )); then ok "utterances still close after an ambient noise step (got $utts)"
else no "utterances still close after an ambient noise step" "got $utts closed utterances"; fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

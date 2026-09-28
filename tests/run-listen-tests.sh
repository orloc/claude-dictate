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
eq "help takes a page"             "$(try_standalone 'skylark help basics')"   $'skylark\thelp\tbasics'
# Proword aliases: what whisper has actually produced for the command words.
eq "a proword alias resolves"      "$(try_standalone 'Bravo, command.')"      $'bravo\topen'
eq "a proword alias reverses too"  "$(try_standalone 'command bravo')"        $'bravo\topen'
eq "silence has aliases"           "$(try_standalone 'alpha silent')"         $'alpha\thush'
eq "radio check alias resolves"    "$(try_standalone 'skylark radio cheque')" $'skylark\tstatus'
eq "an alias is still whole-utterance" "$(try_standalone 'i said bravo command')" "(none)"
# The closing prowords ship without aliases: an alias there widens what can
# end a live transmission, and that is a config decision, not a default.
eq "out has no default alias"      "$(terminal_command 'fix it alpha how' || printf '(none)')" "(none)"

echo "# collapse_repeat"
eq "a stacked command folds to one"  "$(collapse_repeat 'alpha silence alpha silence alpha silence')" "alpha silence"
eq "a stacked single word folds"     "$(collapse_repeat 'out out out out')"                          "out"
eq "a plain command is untouched"    "$(collapse_repeat 'skylark come in')"                          "skylark come in"
eq "a partial repeat is untouched"   "$(collapse_repeat 'alpha silence alpha')"                      "alpha silence alpha"
eq "unequal chunks are untouched"    "$(collapse_repeat 'alpha silence bravo silence')"              "alpha silence bravo silence"
eq "empty stays empty"               "$(collapse_repeat '')"                                         ""
eq "a page alias resolves"         "$(try_standalone 'Skylark, help, manage')" $'skylark\thelp\tmanagement'
# The page must be known, or the prefix match becomes a way for ordinary
# speech starting with the callsign to fire a command.
eq "an unknown page is not a command" "$(try_standalone 'skylark help me move this')" "(none)"
eq "bare help still works"            "$(try_standalone 'skylark help')"          $'skylark\thelp'

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

# The 02:08 case: whisper stacked one "alpha, silence" into four and the
# command was dropped. Stacked in standby is one command; stacked while
# transmitting is dictation and must reach Claude as heard.
STATE=standby; BUFFER=""; SENT=""; TONES=""
say "Alpha silence Alpha silence Alpha silence Alpha silence"
eq "a stacked standby command fires"   "$TONES" "ack"
say "skylark come in"
say "do it again, do it again"
say "skylark out"
eq "repetition in dictation is kept"   "$SENT" "do it again, do it again"

STATE=standby; BUFFER=""; SENT=""; TONES=""
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

# --- help pages -------------------------------------------------------------
echo "# help pages"

# Every command in the tables has to be reachable from some page, or the
# protocol grows a verb nobody can be told about. This is the check that
# catches the next one added without a help line.
help_corpus="$(help_text)$(help_text basics)$(help_text instances)$(help_text management)"
missing=""
for verb in "${!PROWORDS[@]}" "${!MGMT[@]}" kill rename; do
    grep -qiF "$verb" <<<"$help_corpus" || missing="$missing $verb"
done
if [[ -z "$missing" ]]; then ok "every command appears on some help page"
else no "every command appears on some help page" "undocumented:$missing"; fi

# The point of paging is that no single page is a monologue.
for page in "" basics instances management; do
    words=$(help_text "$page" | wc -w)
    if (( words <= 80 )); then ok "help page '${page:-top}' stays short ($words words)"
    else no "help page '${page:-top}' stays short" "$words words"; fi
done

# Top level must not describe instances that do not exist.
# Drive the harness's fake through FAKE_ROSTER rather than redefining
# roster() — replacing it here would leave every later test talking to the
# real one. Both are restored, since ROSTER_CALLS is asserted downstream.
_saved_roster="$FAKE_ROSTER"; _saved_calls="$ROSTER_CALLS"
FAKE_ROSTER=""
if ! grep -qF "alpha" <<<"$(help_text)"; then ok "top level omits instances when none are up"
else no "top level omits instances when none are up" "$(help_text)"; fi
FAKE_ROSTER=$'alpha\t%0\tfocused'
if grep -qF "alpha, focus" <<<"$(help_text)"; then ok "top level mentions instances when they are up"
else no "top level mentions instances when they are up" "$(help_text)"; fi
FAKE_ROSTER="$_saved_roster"; ROSTER_CALLS="$_saved_calls"

say "skylark help management"
eq "a help page stays in standby"      "$STATE"  "standby"
eq "a help page dictates nothing"      "$SENT"   ""
if grep -qF "spawn" <<<"$SPOKEN"; then ok "the management page speaks the management verbs"
else no "the management page speaks the management verbs" "spoke: $SPOKEN"; fi

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
STATE=transmitting; BUFFER="a long thought"; SENT=""
TX_START=$SECONDS; TX_LAST=$SECONDS; MAX_TX=0
check_timeout
eq "timeout closes the mic"  "$STATE" "standby"
eq "timeout sends the buffer" "$SENT" "a long thought"

# The ceiling has to be reached on the path where speech IS arriving. A room
# that keeps talking never goes quiet, so a guard evaluated only during
# silence is a guard that never runs — which is how a phone call ended up
# dictated. pump() is the pairing; drive it the way the read loop does.
pumped() { NEXT_TEXT="$1"; pump "$SANDBOX/nonexistent.wav"; }

# What the ceiling must NOT do is interrupt someone who is still talking. The
# quiet clock restarts on every utterance, so a dictation far longer than
# MAX_TX stays open as long as the gaps are shorter than it.
STATE=transmitting; BUFFER=""; SENT=""; TX_TARGET=skylark
TX_START=$((SECONDS - 600)); TX_LAST=$((SECONDS - 5)); MAX_TX=30; MAX_TX_TOTAL=900
pumped "and then the parser reads the header"
eq "a long dictation is not cut off"   "$STATE"  "transmitting"
eq "a long dictation sends nothing"    "$SENT"   ""
eq "a long dictation keeps buffering"  "$BUFFER" "and then the parser reads the header"

# Quiet is what closes it: nothing said for MAX_TX means you walked away
# without keying out.
STATE=transmitting; BUFFER="a thought nobody closed"; SENT=""; TX_TARGET=skylark
TX_START=$((SECONDS - 100)); TX_LAST=$((SECONDS - 100)); MAX_TX=30
check_timeout
eq "quiet closes the mic"       "$STATE" "standby"
eq "quiet sends what it had"    "$SENT"  "a thought nobody closed"

# Noise whisper finds no words in must not hold the channel open — otherwise
# a fan or a keyboard resets the quiet clock forever.
STATE=transmitting; BUFFER="half a sentence"; SENT=""; TX_TARGET=skylark
TX_START=$((SECONDS - 100)); TX_LAST=$((SECONDS - 100)); MAX_TX=30
pumped ""
eq "an empty transcription does not extend the mic" "$STATE" "standby"
eq "the quiet ceiling still sent the buffer"        "$SENT"  "half a sentence"

# The total ceiling is the backstop for a room that never falls quiet: speech
# keeps resetting the quiet clock, so only elapsed length can catch it.
STATE=transmitting; BUFFER=""; SENT=""; TX_TARGET=skylark
TX_START=$((SECONDS - 100)); TX_LAST=$SECONDS; MAX_TX=900; MAX_TX_TOTAL=60
pumped "someone else entirely is talking now"
eq "continuous speech still hits the total ceiling" "$STATE" "standby"
eq "the total ceiling sends what it had"            "$SENT"  "someone else entirely is talking now"

# ...and zero disables it, for anyone who would rather nothing ever fired but
# silence.
STATE=transmitting; BUFFER=""; SENT=""; TX_TARGET=skylark
TX_START=$((SECONDS - 100000)); TX_LAST=$SECONDS; MAX_TX=900; MAX_TX_TOTAL=0
pumped "still going"
eq "a zero total ceiling never fires" "$STATE" "transmitting"
eq "a zero total ceiling sends nothing" "$SENT" ""

MAX_TX=90; MAX_TX_TOTAL=900

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

# --- tray state -------------------------------------------------------------
# claude-tray draws from listen.state, so every transition has to land there.
echo "# tray state"
mkdir -p "$(dirname "$STATE_FILE")"
pump_say() { NEXT_TEXT="$1"; pump "$SANDBOX/nonexistent.wav"; }
STATE=standby; BUFFER=""; TX_TARGET=""; HEALTH=ok; _PUBLISHED=""
pump_say "skylark come in"
eq "opening publishes transmitting" "$(sed -n 's/^state=//p' "$STATE_FILE")" "transmitting"
eq "the target is published"        "$(sed -n 's/^target=//p' "$STATE_FILE")" "skylark"
eq "the owner's pid is published"   "$(sed -n 's/^pid=//p' "$STATE_FILE")" "$$"
sed -i 's/^since=.*/since=1/' "$STATE_FILE"
pump_say "more words"
eq "unchanged state is not rewritten" "$(sed -n 's/^since=//p' "$STATE_FILE")" "1"
pump_say "skylark disregard"
eq "closing publishes standby"      "$(sed -n 's/^state=//p' "$STATE_FILE")" "standby"
[[ "$(sed -n 's/^since=//p' "$STATE_FILE")" != 1 ]] && ok "a change re-dates since" || no "a change re-dates since"
HEALTH=silent; publish_state
eq "health is published"            "$(sed -n 's/^health=//p' "$STATE_FILE")" "silent"
HEALTH=ok

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
# Records what it was asked to show, so a test can assert on the popups a real
# desktop would have got — including that a repeating condition only raises one.
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notifies"\nexit 0\n' "$SANDBOX" > "$FB/notify-send"
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

# The leak that actually happened, guarded at the source. A child that
# inherits fd 8 holds the singleton flock for as long as it lives, and one of
# the listener's grandchildren is a tmux server: `roster spawn` forked one, it
# inherited the lock, and every later listener then refused to start against a
# process that had been dead for hours. Nothing the listener spawns should see
# that descriptor. Continuation lines are joined first, so a redirection that
# sits on the next line still counts.
leaky=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$SCRIPT" \
        | grep -nE '"\$HERE/claude-|"\$WHISPER" -m' | grep -v '8>&-')
if [[ -z "$leaky" ]]; then ok "no listener child inherits the singleton lock"
else no "no listener child inherits the singleton lock" "$leaky"; fi

# A capture device that has lost its hardware streams zeros instead of failing,
# which is why the mic can go deaf without anything erroring — the headset
# moving to its other card did exactly this for 48 minutes. The fake recorder
# is `cat /dev/zero`, so it is that device; with a short dead-ms the listener
# must notice and rebuild rather than transcribe silence all evening.
: > "$SANDBOX/notifies"   # earlier listeners in this file ran on the same
                         # zero-stream recorder and raised their own popups
dead_out=$(timeout 5 bash -c '
    env -i PATH="'"$FB"':/usr/bin:/bin" HOME="'"$SANDBOX"'" \
        XDG_RUNTIME_DIR="'"$XDG_RUNTIME_DIR"'" XDG_CONFIG_HOME="'"$XDG_CONFIG_HOME"'" \
        DICTATE_WHISPER="'"$FB/fake-whisper"'" DICTATE_MODEL="'"$SANDBOX/model.bin"'" \
        DICTATE_RECORDER="'"$FB/fake-recorder"'" LISTEN_DEAD_MS=200 \
        bash "'"$SCRIPT"'" --run 2>&1 & pid=$!
    sleep 3; kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null' )
if grep -q "digital silence" <<<"$dead_out"; then ok "a silent capture device is noticed"
else no "a silent capture device is noticed" "got: $dead_out"; fi
# It must keep trying — one attempt and then giving up would be a mic that
# never comes back — while telling you only once. A headset that is switched
# off is silent on every device, so a popup per cycle is a popup per dead-ms.
attempts=$(grep -c "digital silence" <<<"$dead_out")
if (( attempts > 1 )); then ok "it keeps re-resolving while the mic stays silent ($attempts attempts)"
else no "it keeps re-resolving while the mic stays silent" "attempts: $attempts"; fi
popups=$(grep -c "mic went silent" "$SANDBOX/notifies" 2>/dev/null || echo 0)
if (( popups == 1 )); then ok "the silence popup is raised once, not per cycle"
else no "the silence popup is raised once, not per cycle" "popups: $popups of $attempts attempts"; fi

# a recorder that isn't installed is refused up front, not respawn-looped
missing_out=$(env -i PATH="$FB:/usr/bin:/bin" HOME="$SANDBOX" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    DICTATE_WHISPER="$FB/fake-whisper" DICTATE_MODEL="$SANDBOX/model.bin" \
    DICTATE_RECORDER="no-such-recorder --flags" \
    bash "$SCRIPT" --run 2>&1); missing_st=$?
eq "a missing recorder is refused at startup" "$missing_st" "1"
if grep -q "recorder not found" <<<"$missing_out"; then ok "the recorder refusal says why"
else no "the recorder refusal says why" "got: $missing_out"; fi

# --- restart ------------------------------------------------------------------
# The tray's "re-detect mic" is --restart: the old listener must be gone before
# the new one asks for the lock, and listen.state must follow the new pid.
echo "# restart"
bg() {
    env -i PATH="$FB:/usr/bin:/bin" HOME="$SANDBOX" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
        DICTATE_WHISPER="$FB/fake-whisper" DICTATE_MODEL="$SANDBOX/model.bin" \
        DICTATE_RECORDER="$FB/fake-recorder" \
        bash "$SCRIPT" "$@" >/dev/null 2>&1
}
state_pid() { sed -n 's/^pid=//p' "$STATE_FILE" 2>/dev/null; }
wait_for() { local i; for i in $(seq 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }

bg --start
wait_for '[[ -n "$(state_pid)" ]]'
p1=$(cat "$PIDFILE" 2>/dev/null)
eq "a started listener publishes its state" "$(state_pid)" "$p1"
bg --restart
wait_for '[[ -n "$(state_pid)" && "$(state_pid)" != "$p1" ]]'
p2=$(cat "$PIDFILE" 2>/dev/null)
if [[ -n "$p2" && "$p2" != "$p1" ]] && ! kill -0 "$p1" 2>/dev/null; then ok "restart replaces the listener"
else no "restart replaces the listener" "p1=$p1 p2=$p2"; fi
eq "the state follows the new listener" "$(state_pid)" "$p2"
bg --stop
wait_for '! kill -0 "$p2" 2>/dev/null'
if [[ ! -e "$STATE_FILE" ]]; then ok "a stopped listener removes its state"
else no "a stopped listener removes its state"; fi

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

# Field measurement: a headset boom's floor sits near -75 dBFS, so a breath at
# -58 is 17 dB above it — "speech" to the margin rule alone, and whisper then
# hallucinates a proword for it. The absolute gate must hold that shut. But
# once a soft voice (-48) has opened the mic, its weak syllables at that same
# -58 must NOT close it: they did, and the sentence reached whisper as
# 1-second fragments it transcribed without context, losing words.
segu() {  # segu "AMP SECS AMP SECS ..." -> closed utterances, 2s of floor around it
    local d="$SANDBOX/seg-${1// /-}"; mkdir -p "$d"
    python3 - $1 <<'PY' | timeout 15 python3 "$TESTS_DIR/../listen-segmenter.py" --outdir "$d" 2>/dev/null | wc -l
import math, struct, sys
out, RATE = sys.stdout.buffer, 16000
def block(a, secs, freq=200):
    for i in range(int(RATE * secs)):
        out.write(struct.pack('<h', int(a * math.sin(2*math.pi*freq*i/RATE))))
block(8, 2)
for a, secs in zip(sys.argv[1::2], sys.argv[2::2]): block(int(a), float(secs))
block(8, 2)
PY
}
eq "a breath 17 dB over a quiet floor does not open the mic" "$(segu "58 1")" "0"
eq "a soft voice over the same floor does" "$(segu "184 1")" "1"
eq "its weak syllables do not split the sentence" "$(segu "184 0.5 58 1 184 0.5")" "1"

# The marker is a contract between the segmenter and the read loop above, so
# pin the exact string: zeros in, "!dead" out, and it stops rather than
# reporting the same dead wire forever.
zeros=$(head -c 32000 /dev/zero | timeout 10 python3 "$TESTS_DIR/../listen-segmenter.py" \
        --outdir "$SANDBOX/seg-dead" --dead-ms 200 2>/dev/null)
eq "digital silence reports !dead once" "$zeros" "!dead"

# Noise must NOT read as a dead device, however quiet — that distinction is the
# whole basis for switching mics, and getting it wrong would cycle the stream
# under someone mid-sentence.
noise=$(python3 -c "
import os, sys, random
random.seed(7)
sys.stdout.buffer.write(bytes(random.randrange(256) for _ in range(32000)))" \
        | timeout 10 python3 "$TESTS_DIR/../listen-segmenter.py" \
              --outdir "$SANDBOX/seg-noise" --dead-ms 200 2>/dev/null | grep -c '^!dead$')
eq "quiet noise is not a dead device" "$noise" "0"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

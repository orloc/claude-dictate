#!/usr/bin/env bash
# Test suite for claude-dictate. Plain bash, no frameworks.
#
# Unit tests source the script and call its functions directly (the script's
# BASH_SOURCE guard makes that safe). Integration tests run the script as a
# subprocess with a scrubbed environment, fake whisper-cli / recorder /
# notify-send binaries, and a throwaway tmux server on a private socket dir.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../claude-dictate"
[[ -f "$SCRIPT" ]] || { echo "script under test not found: $SCRIPT" >&2; exit 2; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

# ---------------------------------------------------------------- sandbox ---
SANDBOX="$(mktemp -d)"
FAKEBIN="$SANDBOX/bin"
RUNTIME="$SANDBOX/runtime"          # becomes XDG_RUNTIME_DIR
CONFHOME="$SANDBOX/config"          # becomes XDG_CONFIG_HOME (empty: no user config leaks)
FAKEHOME="$SANDBOX/home"
TMUXDIR="$SANDBOX/tmux"             # private tmux socket dir (TMUX_TMPDIR)
MODEL_FILE="$SANDBOX/model.bin"
OUT="$SANDBOX/tmux-out.txt"         # what the tmux pane's `cat` captured
SESSION="cd-test-$$-$RANDOM"

mkdir -p "$FAKEBIN" "$RUNTIME" "$CONFHOME" "$FAKEHOME" "$TMUXDIR"
echo "fake ggml model" > "$MODEL_FILE"

cleanup() {
    # kill a leftover fake recorder if a test aborted mid-toggle
    if [[ -f "$RUNTIME/claude-dictate/rec.pid" ]]; then
        kill "$(cat "$RUNTIME/claude-dictate/rec.pid")" 2>/dev/null
    fi
    TMUX_TMPDIR="$TMUXDIR" tmux kill-server 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

# ------------------------------------------------------------------ fakes ---
# no-op notify-send so desktop notifications don't fire during tests
cat > "$FAKEBIN/notify-send" <<'EOF'
#!/bin/sh
exit 0
EOF

# canned whisper-cli: validates -m/-f point at real files, prints canned text
cat > "$FAKEBIN/whisper-cli" <<'EOF'
#!/usr/bin/env bash
model="" wav=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) model="${2-}"; shift 2 ;;
        -f) wav="${2-}";   shift 2 ;;
        *)  shift ;;
    esac
done
[[ -n "$model" && -f "$model" ]] || { echo "fake whisper: missing/bad -m" >&2; exit 2; }
[[ -n "$wav"   && -f "$wav"   ]] || { echo "fake whisper: missing/bad -f" >&2; exit 2; }
printf '%s\n' "${FAKE_WHISPER_TEXT-testing one two three}"
EOF

# whisper variant that always fails
cat > "$FAKEBIN/whisper-cli-fail" <<'EOF'
#!/usr/bin/env bash
echo "fake whisper: boom" >&2
exit 1
EOF

# fake recorder: writes FAKE_WAV_BYTES (default 20000, 0 = write nothing) to
# the wav path it is handed, then idles until SIGTERM
cat > "$FAKEBIN/fake-recorder" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM
bytes="${FAKE_WAV_BYTES:-20000}"
if (( bytes > 0 )); then
    head -c "$bytes" /dev/zero > "$1"
fi
while :; do sleep 0.05; done
EOF

chmod +x "$FAKEBIN"/*

# --------------------------------------------------------------- asserts ----
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

assert_eq() { # desc expected actual
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected [$2], got [$3])"; fi
}
assert_status() { # desc expected_status actual_status
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected exit $2, got $3)"; fi
}

# ------------------------------------------------------------- unit tests ---
# Source the script with a scrubbed config location so ~/.config/claude-dictate
# never leaks in. The guard line `[[ ... ]] && main` returns 1 when sourced,
# hence the `|| true`.
unset DICTATE_WHISPER DICTATE_MODEL DICTATE_TARGET DICTATE_RECORDER 2>/dev/null
XDG_CONFIG_HOME="$CONFHOME" XDG_RUNTIME_DIR="$RUNTIME" source "$SCRIPT" || true

echo "# clean_text"
assert_eq "collapses runs of internal whitespace" \
    "hello world" "$(clean_text <<< 'hello    world')"
assert_eq "joins multi-line input into one line" \
    "foo bar baz" "$(clean_text <<< $'foo\nbar\n  baz')"
assert_eq "strips leading and trailing space" \
    "hi there" "$(clean_text <<< '   hi there   ')"
assert_eq "squeezes tabs and mixed whitespace" \
    "a b c" "$(clean_text <<< $'a\t\tb  \n c')"
assert_eq "strips bracketed non-speech markers" \
    "" "$(clean_text <<< '[BLANK_AUDIO]')"
assert_eq "strips parenthesized non-speech markers" \
    "hello there" "$(clean_text <<< '(coughing) hello there')"

echo "# is_hallucination"
hall() { # desc input expected_status(0=hallucination,1=real)
    local st=0
    is_hallucination "$2" || st=$?
    assert_status "$1" "$3" "$st"
}
hall "empty string is a hallucination"      ""                     0
hall "'you' is a hallucination"             "you"                  0
hall "'You.' is a hallucination"            "You."                 0
hall "'Thank you.' is a hallucination"      "Thank you."           0
hall "'bye' is a hallucination"             "bye"                  0
hall "'Thanks for watching!' hallucination" "Thanks for watching!" 0
hall "'Thanks for watching.' hallucination" "Thanks for watching." 0
hall "'You...' is a hallucination"          "You..."               0
hall "'fix the bug' is NOT a hallucination" "fix the bug"          1
hall "'you too' is NOT a hallucination"     "you too"              1

# sourcing the script must not report failure (the BASH_SOURCE guard is if-form)
st=0
(XDG_CONFIG_HOME="$CONFHOME" XDG_RUNTIME_DIR="$RUNTIME" source "$SCRIPT") || st=$?
assert_status "sourcing the script exits 0" 0 "$st"

# ------------------------------------------------------ integration setup ---
echo "# integration"

# append mode: `: > "$OUT"` between flows truncates the file, and O_APPEND
# keeps cat writing at the real EOF instead of leaving a NUL hole at its old offset
TMUX_TMPDIR="$TMUXDIR" tmux new-session -d -s "$SESSION" "cat >> $OUT" \
    || { echo "could not start throwaway tmux session" >&2; exit 2; }

PIDFILE="$RUNTIME/claude-dictate/rec.pid"
WAVFILE="$RUNTIME/claude-dictate/rec.wav"

# Run the script in a scrubbed environment (env -i) so no user config or
# DICTATE_* vars leak in. Extra VAR=val args are appended to the environment.
run_dictate() {
    env -i \
        HOME="$FAKEHOME" \
        PATH="$FAKEBIN:/usr/bin:/bin:/usr/local/bin" \
        XDG_CONFIG_HOME="$CONFHOME" \
        XDG_RUNTIME_DIR="$RUNTIME" \
        TMUX_TMPDIR="$TMUXDIR" \
        DICTATE_MODEL="$MODEL_FILE" \
        DICTATE_TARGET="$SESSION" \
        DICTATE_RECORDER="$FAKEBIN/fake-recorder" \
        "$@" \
        bash "$SCRIPT" 2>/dev/null
}

# Wait until the recorder (spawned async by the start press) has produced the
# wav, so the stop press's size gate sees the finished file.
wait_for_wav() {
    for _ in $(seq 1 50); do
        [[ -s "$WAVFILE" ]] && return 0
        sleep 0.1
    done
    return 1
}

wait_for_out() { # wait for the injected line to land in the tmux pane's cat
    for _ in $(seq 1 50); do
        [[ -s "$OUT" ]] && return 0
        sleep 0.1
    done
    return 1
}

# --- happy path: start press then stop press ---------------------------------
: > "$OUT"
run_dictate
st=$?
assert_status "start press exits 0" 0 "$st"
if [[ -f "$PIDFILE" ]]; then
    pass "start press creates pidfile"
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        pass "recorder process is running"
    else
        fail "recorder process is running"
    fi
else
    fail "start press creates pidfile"
    fail "recorder process is running"
fi
wait_for_wav || fail "recorder wrote wav (setup)"

run_dictate FAKE_WHISPER_TEXT='  testing   one two three  '
st=$?
assert_status "stop press exits 0" 0 "$st"
[[ -f "$PIDFILE" ]] && fail "stop press removes pidfile" || pass "stop press removes pidfile"
if wait_for_out; then
    assert_eq "cleaned transcript injected into tmux" \
        "testing one two three" "$(cat "$OUT")"
    # command substitution above strips the trailing newline; verify the Enter
    # keypress actually arrived by checking the file's last byte is \n
    if [[ -z "$(tail -c1 "$OUT")" ]]; then
        pass "injection ends with newline (Enter sent)"
    else
        fail "injection ends with newline (Enter sent)"
    fi
else
    fail "cleaned transcript injected into tmux (nothing arrived)"
    fail "injection ends with newline (Enter sent)"
fi

# --- tiny wav: below MIN_WAV_BYTES -> heard nothing, no injection ------------
: > "$OUT"
run_dictate FAKE_WAV_BYTES=100
sleep 0.5   # let the recorder write its (tiny) wav
run_dictate FAKE_WAV_BYTES=100
st=$?
assert_status "tiny wav: stop press exits 0" 0 "$st"
sleep 0.5
assert_eq "tiny wav: nothing injected" "" "$(cat "$OUT")"

# --- missing wav: recorder never wrote a file --------------------------------
: > "$OUT"
run_dictate FAKE_WAV_BYTES=0
sleep 0.5
run_dictate FAKE_WAV_BYTES=0
st=$?
assert_status "missing wav: stop press exits 0" 0 "$st"
sleep 0.5
assert_eq "missing wav: nothing injected" "" "$(cat "$OUT")"

# --- whisper failure: script must die nonzero, inject nothing ----------------
: > "$OUT"
run_dictate DICTATE_WHISPER=whisper-cli-fail
wait_for_wav || fail "recorder wrote wav (whisper-fail setup)"
run_dictate DICTATE_WHISPER=whisper-cli-fail
st=$?
if (( st != 0 )); then
    pass "whisper failure: script exits nonzero"
else
    fail "whisper failure: script exits nonzero (got 0)"
fi
sleep 0.5
assert_eq "whisper failure: nothing injected" "" "$(cat "$OUT")"

# --- hallucination transcript: filtered, no injection ------------------------
: > "$OUT"
run_dictate
wait_for_wav || fail "recorder wrote wav (hallucination setup)"
run_dictate FAKE_WHISPER_TEXT='Thank you.'
st=$?
assert_status "hallucination: stop press exits 0" 0 "$st"
sleep 0.5
assert_eq "hallucination: nothing injected" "" "$(cat "$OUT")"

# --- tmux-hostile transcripts: leading dash, trailing semicolon --------------
: > "$OUT"
run_dictate
wait_for_wav || fail "recorder wrote wav (leading-dash setup)"
run_dictate FAKE_WHISPER_TEXT='- Yes, go ahead.'
assert_status "leading dash: stop press exits 0" 0 "$?"
if wait_for_out; then
    assert_eq "leading dash injected intact" "- Yes, go ahead." "$(cat "$OUT")"
else
    fail "leading dash injected intact (nothing arrived)"
fi

: > "$OUT"
run_dictate
wait_for_wav || fail "recorder wrote wav (semicolon setup)"
run_dictate FAKE_WHISPER_TEXT='echo done;'
assert_status "trailing semicolon: stop press exits 0" 0 "$?"
if wait_for_out; then
    assert_eq "trailing semicolon injected intact" "echo done;" "$(cat "$OUT")"
else
    fail "trailing semicolon injected intact (nothing arrived)"
fi

# --- stale pidfile: a recycled PID must not be killed ------------------------
: > "$OUT"
sleep 60 &
BYSTANDER=$!
mkdir -p "$(dirname "$PIDFILE")"
echo "$BYSTANDER" > "$PIDFILE"
rm -f "$WAVFILE"
run_dictate
assert_status "stale pidfile: stop press exits 0" 0 "$?"
if kill -0 "$BYSTANDER" 2>/dev/null; then
    pass "stale pidfile: unrelated process not killed"
else
    fail "stale pidfile: unrelated process not killed"
fi
kill "$BYSTANDER" 2>/dev/null
sleep 0.5
assert_eq "stale pidfile: nothing injected" "" "$(cat "$OUT")"

# ---------------------------------------------------------------- summary ---
echo
echo "passed: $PASS  failed: $FAIL"
(( FAIL == 0 )) || exit 1
exit 0

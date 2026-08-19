#!/usr/bin/env bash
# Test suite for claude-speak. Plain bash, no frameworks.
#
# Everything runs the script as a subprocess with a scrubbed environment and a
# fake sherpa CLI that logs the text it was asked to synthesize — so the
# assertions are about what would actually be spoken, cleaning and chunking
# together, rather than about the regexes in isolation.
#
# claude-speak detaches itself with setsid, so each case waits for the run to
# finish rather than assuming it completed on return.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../claude-speak"
[[ -f "$SCRIPT" ]] || { echo "script under test not found: $SCRIPT" >&2; exit 2; }
SCRIPT="$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")"

# ---------------------------------------------------------------- sandbox ---
SANDBOX="$(mktemp -d)"
FAKEBIN="$SANDBOX/bin"
RUNTIME="$SANDBOX/runtime"
CONFHOME="$SANDBOX/config"
MODEL_DIR="$SANDBOX/model"
SPOKEN="$SANDBOX/spoken.txt"        # one line per synthesized chunk
PLAYED="$SANDBOX/played.txt"        # one line per playback invocation, with argv

mkdir -p "$FAKEBIN" "$RUNTIME" "$CONFHOME" "$MODEL_DIR"
# resolveModel only insists on the onnx; the rest are passed as flags
echo "fake kokoro model" > "$MODEL_DIR/model.int8.onnx"

cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

# ------------------------------------------------------------------ fakes ---
# sherpa stand-in: logs the text (last positional) and writes a nonempty wav
cat > "$FAKEBIN/fake-sherpa" <<'EOF'
#!/usr/bin/env bash
out=""
for a in "$@"; do
    case "$a" in --output-filename=*) out="${a#--output-filename=}" ;; esac
done
text="${!#}"
printf '%s\n' "$text" >> "$SPOKEN_LOG"
[[ -n "$out" ]] && printf 'RIFFfake' > "$out"
exit 0
EOF

# swallow playback so the suite is silent and instant, logging the argv so the
# routing tests can see which device was asked for
for p in paplay aplay ffplay pw-play; do
    cat > "$FAKEBIN/$p" <<EOF
#!/bin/sh
printf '$p %s\n' "\$*" >> "\$PLAYED_LOG"
exit 0
EOF
done
chmod +x "$FAKEBIN"/*

# ------------------------------------------------------------------ harness -
pass=0 fail=0
ok()  { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no()  { printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; fail=$((fail + 1)); }

check()   { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }
has()     { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else no "$1" "[$3] missing from [$2]"; fi; }
hasnt()   { if grep -qF -- "$3" <<<"$2"; then no "$1" "[$3] should not appear in [$2]"; else ok "$1"; fi; }

# say TEXT [env assignments...] — runs the script, waits, echoes what was spoken
say() {
    local text="$1"; shift
    : > "$SPOKEN"; : > "$PLAYED"
    rm -rf "${RUNTIME:?}/claude-dictate"
    printf '%s' "$text" | env -i \
        PATH="$FAKEBIN:/usr/bin:/bin" \
        HOME="$SANDBOX" \
        XDG_RUNTIME_DIR="$RUNTIME" \
        XDG_CONFIG_HOME="$CONFHOME" \
        SPOKEN_LOG="$SPOKEN" \
        PLAYED_LOG="$PLAYED" \
        SPEAK_ENGINE="$FAKEBIN/fake-sherpa" \
        SPEAK_MODEL_DIR="$MODEL_DIR" \
        "$@" \
        bash "$SCRIPT" >/dev/null 2>&1
    # the run is detached; wait for it to finish rather than racing it
    local i
    for (( i = 0; i < 100; i++ )); do
        pgrep -f "claude-speak --speak" >/dev/null 2>&1 || break
        sleep 0.05
    done
    cat "$SPOKEN" 2>/dev/null
}

echo "# claude-speak"

# --- cleaning ---------------------------------------------------------------
out=$(say 'Here is the fix:

```sh
rm -rf /everything
```

That should do it.')
hasnt "fenced code block is not spoken" "$out" "rm -rf"
has   "prose around a code block survives" "$out" "That should do it."

out=$(say 'See the [documentation](https://example.com/a/b) for details.')
has   "link text is kept" "$out" "documentation"
hasnt "link url is not spoken" "$out" "example.com"

out=$(say 'Edited /home/orloc/dev/claude-dictate/claude-speak today.')
has   "long path is reduced to its basename" "$out" "claude-speak"
hasnt "path directories are not spoken" "$out" "/home/orloc"

out=$(say '| col | col2 |
|-----|------|
| a   | b    |
Real prose here.')
hasnt "table rows are not spoken" "$out" "col2"
has   "prose beside a table survives" "$out" "Real prose here."

out=$(say 'This is **bold** and this is `code`.')
hasnt "bold markers stripped" "$out" '**'
hasnt "backticks stripped" "$out" '`'
has   "emphasized words survive" "$out" "bold"

out=$(say '- first item
- second item')
has "bullets become sentences" "$out" "first item."

out=$(say 'Done ✓ and arrows → gone 🎉')
hasnt "emoji are not spoken" "$out" "🎉"
hasnt "arrows are not spoken" "$out" "→"

# --- nothing worth saying ---------------------------------------------------
out=$(say '')
check "empty input synthesizes nothing" "$out" ""

out=$(say '```
only a code block
```')
check "code-block-only input synthesizes nothing" "$out" ""

out=$(say '### ***')
check "punctuation-only input synthesizes nothing" "$out" ""

out=$(say 'This should stay quiet.' SPEAK_ENABLED=0)
check "SPEAK_ENABLED=0 synthesizes nothing" "$out" ""

# --- chunking and truncation ------------------------------------------------
long='One sentence here. Two sentence here. Three sentence here. Four sentence here.
Five sentence here. Six sentence here. Seven sentence here. Eight sentence here.
Nine sentence here. Ten sentence here. Eleven here. Twelve here. Thirteen here.'
out=$(say "$long")
n=$(wc -l <<<"$out")
if (( n > 1 )); then ok "long text is split into multiple chunks"
else no "long text is split into multiple chunks" "got $n chunk(s)"; fi

out=$(say "$long" SPEAK_MAX_CHARS=60)
has "over-long text is truncated with a notice" "$out" "Response truncated."
hasnt "text past the cap is dropped" "$out" "Thirteen here"

# --- output routing ---------------------------------------------------------
say 'Routed speech.' SPEAK_SINK=some_headset_sink >/dev/null
out=$(cat "$PLAYED")
has "a pinned sink is passed to the player" "$out" "--target some_headset_sink"

say 'Unrouted speech.' >/dev/null
out=$(cat "$PLAYED")
hasnt "no sink pinned means no device flag" "$out" "--target"
has   "unpinned playback still happens" "$out" "paplay"

# DICTATE_RECORDER's mic should pick the sink on the same card without the user
# configuring the output separately.
say 'Follow the mic.' DICTATE_RECORDER="pw-record --target alsa_input.usb-Nope_Fake-00.mono-fallback" >/dev/null
out=$(cat "$PLAYED")
hasnt "an unmatchable mic card falls back to the default device" "$out" "--target alsa_output"

# --- stop -------------------------------------------------------------------
env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$SANDBOX" \
    XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$CONFHOME" \
    bash "$SCRIPT" --stop >/dev/null 2>&1
check "--stop with nothing playing exits 0" "$?" "0"

printf 'not a number\n' > "$RUNTIME/claude-dictate/speak.pgid" 2>/dev/null || {
    mkdir -p "$RUNTIME/claude-dictate"
    printf 'not a number\n' > "$RUNTIME/claude-dictate/speak.pgid"
}
env -i PATH="$FAKEBIN:/usr/bin:/bin" HOME="$SANDBOX" \
    XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$CONFHOME" \
    bash "$SCRIPT" --stop >/dev/null 2>&1
check "--stop tolerates a garbage pgid file" "$?" "0"

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

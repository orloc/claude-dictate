#!/usr/bin/env bash
# Test suite for claude-mic. Plain bash, no frameworks.
#
# The script is driven as a subprocess with fake `pactl` and `pw-record` on
# PATH, so a whole headset can be plugged, unplugged and switched between its
# dongle and its cable without any audio hardware being involved. The fakes are
# the interesting part: FAKE_SOURCES is the device list pactl reports, and
# FAKE_LIVE is which of those devices actually carries sound — the distinction
# the real bug turned on, since the losing device stays listed and streams
# zeros rather than disappearing.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../claude-mic"
[[ -f "$SCRIPT" ]] || { echo "script under test not found: $SCRIPT" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

export XDG_CONFIG_HOME="$SANDBOX/config"
export XDG_RUNTIME_DIR="$SANDBOX/runtime"
mkdir -p "$XDG_CONFIG_HOME/claude-dictate" "$XDG_RUNTIME_DIR"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }

# --- fakes ------------------------------------------------------------------
FB="$SANDBOX/bin"; mkdir -p "$FB"

# pactl: prints $FAKE_SOURCES in the short-list shape, index/name/driver/...
cat > "$FB/pactl" <<'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "list short" && "$3" == "sources" ]]; then
    i=50
    for n in ${FAKE_SOURCES:-}; do
        printf '%s\t%s\tPipeWire\ts16le 1ch 16000Hz\tSUSPENDED\n' "$i" "$n"
        i=$((i + 1))
    done
fi
exit 0
EOF

# pw-record: writes a wav-shaped file — a header full of nonzero bytes, then
# either noise or exact zeros depending on whether this device is in FAKE_LIVE.
# That is the real device's behaviour: a dongle with no headset behind it keeps
# streaming, it just streams silence.
cat > "$FB/pw-record" <<'EOF'
#!/usr/bin/env bash
target=""; out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) target="$2"; shift 2 ;;
        --rate|--channels|--format) shift 2 ;;
        *) out="$1"; shift ;;
    esac
done
[[ -n "$out" ]] || exit 1
printf 'RIFF....WAVEfmt short-header-that-is-not-audio' > "$out"
head -c 1024 /dev/zero >> "$out"
if [[ " ${FAKE_LIVE:-} " == *" $target "* ]]; then
    head -c 4096 /dev/urandom >> "$out"
else
    head -c 4096 /dev/zero >> "$out"
fi
sleep 5   # the real one runs until killed
EOF

# A stand-in for the recorder --record execs into, so the exec'd argv can be
# asserted without pw-record's fake having to double as both.
cat > "$FB/echo-record" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV: %s\n' "$*"
EOF
chmod +x "$FB"/*

DONGLE=alsa_input.usb-Corsair_HS35_v3_WL_0123456789AB-01.mono-fallback
CABLE=alsa_input.usb-Corsair_HS35_v3_Wireless_Gaming_Headset_0123456789AB-01.mono-fallback
SPDIF=alsa_input.usb-Generic_USB_Audio-00.iec958-stereo
MONITOR=alsa_output.usb-Corsair_HS35_v3_WL_0123456789AB-01.analog-stereo.monitor

mic() { # mic SOURCES LIVE [args...]
    local sources="$1" live="$2"; shift 2
    env PATH="$FB:/usr/bin:/bin" HOME="$SANDBOX" \
        XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        FAKE_SOURCES="$sources" FAKE_LIVE="$live" \
        DICTATE_MIC_MATCH="${MATCH:-Corsair}" DICTATE_MIC_PROBE_MS=60 \
        bash "$SCRIPT" "$@"
}
forget() { mic "" "" --forget >/dev/null 2>&1; }

# --- resolution -------------------------------------------------------------
echo "# resolution"

# The failure this exists for: both cards are listed, only one carries sound.
# A name-based rule cannot tell them apart, which is how the mic went deaf.
forget
eq "the live card wins over the silent one" \
   "$(mic "$DONGLE $CABLE" "$CABLE" --resolve)" "$CABLE"

# ...and the same list resolves the other way when the headset moves back,
# without any config changing. This is the whole point.
forget
eq "unplugging moves it back to the dongle" \
   "$(mic "$DONGLE $CABLE" "$DONGLE" --resolve)" "$DONGLE"

forget
eq "a lone device is used even when listed first" \
   "$(mic "$DONGLE" "$DONGLE" --resolve)" "$DONGLE"

# Nothing live at all — headset switched off. A name is still better than
# nothing: the recorder starts, fails audibly, and the listener retries.
forget
eq "with nothing live it falls back to a candidate" \
   "$(mic "$DONGLE $CABLE" "" --resolve)" "$DONGLE"

forget
eq "no candidate at all is an error" "$(mic "$SPDIF" "$SPDIF" --resolve >/dev/null 2>&1; echo $?)" "1"

# --- what counts as a candidate ---------------------------------------------
echo "# candidates"

# The match is what keeps a machine's real mic from losing to whatever else
# happens to be live — this box's S/PDIF input reads as live while carrying
# nothing at all.
forget
eq "the match excludes other live inputs" \
   "$(mic "$SPDIF $CABLE" "$SPDIF $CABLE" --resolve)" "$CABLE"

# A monitor carries what the speakers are playing. Recording one makes the
# listener transcribe its own voice, so it is never a candidate.
MATCH=. forget
eq "monitors are never candidates" \
   "$(MATCH=. mic "$MONITOR $CABLE" "$MONITOR $CABLE" --resolve)" "$CABLE"

# --- caching ----------------------------------------------------------------
echo "# caching"

# The cache exists so the hotkey path doesn't pay for a probe before the mic
# opens — a probe there clips the first word.
forget
mic "$DONGLE $CABLE" "$CABLE" --resolve >/dev/null
eq "a repeat answers from cache" \
   "$(mic "$DONGLE $CABLE" "" --resolve)" "$CABLE"

# But a cache that outlives the truth is the bug all over again, so the
# candidate list is the key: plug the cable in, and the answer is recomputed.
eq "a changed device list invalidates the cache" \
   "$(mic "$DONGLE" "$DONGLE" --resolve)" "$DONGLE"

# The listener calls --forget when its stream turns out to be silent: same
# devices, different answer.
mic "$DONGLE $CABLE" "$CABLE" --resolve >/dev/null
mic "$DONGLE $CABLE" "$CABLE" --forget
eq "--forget makes it measure again" \
   "$(mic "$DONGLE $CABLE" "$DONGLE" --resolve)" "$DONGLE"

# --- publishing -------------------------------------------------------------
echo "# publishing"

# claude-speak reads this file to pick the sink to answer through, so the
# reply comes out of the headset you are talking into rather than the last
# device someone pinned by hand.
forget
mic "$DONGLE $CABLE" "$CABLE" --resolve >/dev/null
eq "the resolved source is published" "$(cat "$XDG_RUNTIME_DIR/claude-dictate/mic")" "$CABLE"

# --- recording --------------------------------------------------------------
echo "# recording"

# --record has to pass its arguments through untouched and put --target in
# front of them, or the recorder's format contract with the segmenter breaks.
forget
argv=$(PATH="$FB:/usr/bin:/bin" bash -c '
    export FAKE_SOURCES="'"$DONGLE $CABLE"'" FAKE_LIVE="'"$CABLE"'"
    export XDG_CONFIG_HOME="'"$XDG_CONFIG_HOME"'" XDG_RUNTIME_DIR="'"$XDG_RUNTIME_DIR"'"
    export DICTATE_MIC_MATCH=Corsair DICTATE_MIC_PROBE_MS=60
    sed "s|exec pw-record|exec echo-record|" "'"$SCRIPT"'" > "'"$SANDBOX"'/mic-exec"
    bash "'"$SANDBOX"'/mic-exec" --record --rate 16000 --channels 1 --format s16 -')
eq "--record targets the live device and passes the rest through" \
   "$argv" "ARGV: --target $CABLE -P { node.dont-reconnect = true } --rate 16000 --channels 1 --format s16 -"

# The property is the whole reason a wrong device gets noticed. Without it a
# vanished node does not end the stream — PipeWire moves it to the default
# source, and a stream that is alive, real-time and non-zero looks perfect from
# every angle while carrying nothing. Assert it explicitly, because the symptom
# if it silently disappears is a mic that lies rather than one that fails.
if grep -qF "node.dont-reconnect = true" <<<"$argv"; then ok "the recorder refuses to be relinked"
else no "the recorder refuses to be relinked" "$argv"; fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

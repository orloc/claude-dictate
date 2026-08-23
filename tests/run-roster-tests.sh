#!/usr/bin/env bash
# Test suite for claude-roster. Plain bash, no frameworks.
#
# Everything runs against a REAL tmux server on a private socket dir — the
# roster's whole job is keeping a file in sync with live panes, so faking tmux
# would test nothing. The script is copied into a sandbox so its claude-speak
# sibling can be a recorder.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$TESTS_DIR/../claude-roster"
[[ -f "$REAL" ]] || { echo "script under test not found: $REAL" >&2; exit 2; }

SANDBOX="$(mktemp -d)"
# A set TMUX makes every tmux client ignore TMUX_TMPDIR and target the
# caller's real server — the kill-server in cleanup would then kill the
# session hosting this very test run (see run-tests.sh for the incident).
unset TMUX TMUX_PANE

RUNTIME="$SANDBOX/runtime"
CONFHOME="$SANDBOX/config"
TMUXDIR="$SANDBOX/tmux"
SESSION="cr-test-$$-$RANDOM"
STOPS="$SANDBOX/stops.txt"
mkdir -p "$RUNTIME" "$CONFHOME" "$TMUXDIR"

cleanup() {
    # kill-server by explicit socket path, never by TMUX_TMPDIR: this tmux
    # build silently falls back to the REAL default socket when TMUX_TMPDIR
    # names a directory that no longer exists (see run-tests.sh cleanup).
    tmux -S "$TMUXDIR/tmux-$(id -u)/default" kill-server 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

SCRIPT="$SANDBOX/claude-roster"
cp "$REAL" "$SCRIPT"; chmod +x "$SCRIPT"
cat > "$SANDBOX/claude-speak" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--stop" ]] && echo stop >> "$STOPS"
exit 0
EOF
chmod +x "$SANDBOX/claude-speak"

pass=0 fail=0
ok() { printf 'ok   - %s\n' "$1"; pass=$((pass + 1)); }
no() { printf 'FAIL - %s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "want [$3] got [$2]"; fi; }

roster() {
    env -i PATH=/usr/bin:/bin HOME="$SANDBOX" \
        XDG_RUNTIME_DIR="$RUNTIME" XDG_CONFIG_HOME="$CONFHOME" \
        TMUX_TMPDIR="$TMUXDIR" \
        DICTATE_TARGET="$SESSION" \
        DICTATE_SPAWN_CMD="sleep 300" \
        LISTEN_POOL="alpha bravo charlie" \
        bash "$SCRIPT" "$@" 2>/dev/null
}

FOCUS="$RUNTIME/claude-dictate/focus-pane"
panes() { TMUX_TMPDIR="$TMUXDIR" tmux list-panes -s -t "=$SESSION" -F '#{pane_id}' 2>/dev/null; }
active_pane() { TMUX_TMPDIR="$TMUXDIR" tmux display-message -t "=$SESSION:" -p '#{pane_id}' 2>/dev/null; }

# --- spawn --------------------------------------------------------------------
echo "# spawn"
out=$(roster spawn); st=$?
eq "first spawn exits 0"                 "$st" "0"
eq "first spawn claims the first name"   "${out%%$'\t'*}" "alpha"
P_ALPHA="${out#*$'\t'}"
if TMUX_TMPDIR="$TMUXDIR" tmux has-session -t "=$SESSION" 2>/dev/null; then
    ok "first spawn bootstraps the session"
else
    no "first spawn bootstraps the session"
fi
eq "the first instance is focused"       "$(cat "$FOCUS" 2>/dev/null)" "$P_ALPHA"

out=$(roster spawn)
eq "second spawn claims the next name"   "${out%%$'\t'*}" "bravo"
P_BRAVO="${out#*$'\t'}"
eq "the session now has two panes"       "$(panes | grep -c .)" "2"
eq "a later spawn leaves focus alone"    "$(cat "$FOCUS" 2>/dev/null)" "$P_ALPHA"

# --- list / pane / status -------------------------------------------------------
echo "# list, pane, status"
eq "list shows both, with the focus marked" \
   "$(roster list)" "$(printf 'alpha\t%s\tfocused\nbravo\t%s\t-' "$P_ALPHA" "$P_BRAVO")"
eq "pane resolves a name"                "$(roster pane bravo)" "$P_BRAVO"
roster pane nosuch >/dev/null; st=$?
eq "pane on an unknown name fails"       "$st" "1"
eq "status is one human line" \
   "$(roster status)" "2 up (alpha bravo), focused: alpha"

# --- focus ----------------------------------------------------------------------
echo "# focus"
roster focus bravo >/dev/null
eq "focus rewrites the focus file"       "$(cat "$FOCUS" 2>/dev/null)" "$P_BRAVO"
eq "focus moves the tmux cursor"         "$(active_pane)" "$P_BRAVO"
eq "focus silences the previous speaker" "$(grep -c stop "$STOPS" 2>/dev/null)" "1"
roster focus nosuch >/dev/null; st=$?
eq "focusing an unknown name fails"      "$st" "1"

# --- rename ---------------------------------------------------------------------
echo "# rename"
roster rename alpha charlie >/dev/null
eq "the new name resolves to the old pane" "$(roster pane charlie)" "$P_ALPHA"
roster pane alpha >/dev/null; st=$?
eq "the old name is gone"                "$st" "1"
eq "a rename never touches the focus"    "$(cat "$FOCUS" 2>/dev/null)" "$P_BRAVO"
roster rename charlie bravo >/dev/null; st=$?
eq "renaming onto a name in use fails"   "$st" "1"
roster rename charlie zulu >/dev/null; st=$?
eq "renaming outside the pool fails"     "$st" "1"
roster rename charlie alpha >/dev/null   # put it back

# --- kill -----------------------------------------------------------------------
echo "# kill"
roster kill bravo >/dev/null; st=$?
eq "kill exits 0"                        "$st" "0"
eq "the pane is gone"                    "$(panes | grep -c .)" "1"
roster pane bravo >/dev/null; st=$?
eq "the name is gone from the roster"    "$st" "1"
eq "killing the focused one refocuses a survivor" "$(cat "$FOCUS" 2>/dev/null)" "$P_ALPHA"
roster kill nosuch >/dev/null; st=$?
eq "killing an unknown name fails"       "$st" "1"

# --- reap -----------------------------------------------------------------------
echo "# reap"
out=$(roster spawn); P_GHOST="${out#*$'\t'}"
TMUX_TMPDIR="$TMUXDIR" tmux kill-pane -t "$P_GHOST"     # closed by hand, not through the roster
eq "reap names the ghost it drops"       "$(roster reap)" "bravo"
eq "the ghost is gone from list"         "$(roster list | cut -f1)" "alpha"
eq "a clean reap drops nothing"          "$(roster reap)" ""

# --- pool exhaustion --------------------------------------------------------------
echo "# pool exhaustion"
roster spawn >/dev/null
roster spawn >/dev/null
roster spawn >/dev/null; st=$?
eq "a spawn past the pool is refused"    "$st" "1"
eq "the pool names are all in use"       "$(roster list | cut -f1 | sort | paste -sd' ')" "alpha bravo charlie"

# --- the last kill ----------------------------------------------------------------
echo "# the last kill"
roster kill bravo >/dev/null
roster kill charlie >/dev/null
roster kill alpha >/dev/null
eq "killing the last instance empties the roster" "$(roster list)" ""
eq "status reports the empty roster"     "$(roster status)" "no instances"
if [[ -f "$FOCUS" ]]; then no "an empty roster clears the focus file"
else ok "an empty roster clears the focus file"; fi

# --- concurrency -------------------------------------------------------------------
echo "# concurrency"
# Two racing spawns must claim different names — the roster lock serializes
# the claim, or both would come up as alpha.
roster spawn >/dev/null &
roster spawn >/dev/null &
wait
eq "racing spawns claim distinct names" \
   "$(roster list | cut -f1 | sort | paste -sd' ')" "alpha bravo"

echo "# lock hygiene"
# A tmux client that has to auto-start the server hands it every open fd, and
# the server holds them for its whole life — so a lock fd reaching it is a lock
# nothing can ever take again. It happened: a spawn from the listener left the
# server sitting on the listener's singleton lock (fd 8), and every later
# listener refused to start against a corpse. Both suite locks must be closed
# at the calls that can fork a server.
leaky=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$SCRIPT" \
        | grep -nE 'tmux (has-session|new-session|split-window|select-layout)' \
        | grep -v '8>&-')
if [[ -z "$leaky" ]]; then ok "no tmux client inherits a suite lock"
else no "no tmux client inherits a suite lock" "$leaky"; fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

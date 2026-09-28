#!/usr/bin/env bash
# Test suite for claude-tray. Plain bash driving python; no display needed.
#
# The tray is loaded as a module and pointed at a sandbox runtime dir, so the
# icon/tooltip logic is checked against the files the other scripts publish,
# and the action helpers against real child processes.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TESTS_DIR/../claude-tray"
[[ -f "$SCRIPT" ]] || { echo "script under test not found: $SCRIPT" >&2; exit 2; }
python3 -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null \
    || { echo "skipping: PyGObject with GTK 3 not available"; exit 0; }

SANDBOX="$(mktemp -d)"
trap 'pkill -f "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/claude-dictate"

env -u DISPLAY -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$SANDBOX" TERMINAL= \
    python3 - "$SCRIPT" "$SANDBOX/claude-dictate" <<'PY'
import importlib.machinery, importlib.util, os, subprocess, sys, time

script, run_dir = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("tray", script)
tray = importlib.util.module_from_spec(importlib.util.spec_from_loader("tray", loader))
loader.exec_module(tray)
from gi.repository import GLib

passed = failed = 0
def eq(name, got, want):
    global passed, failed
    if got == want:
        print(f"ok   - {name}"); passed += 1
    else:
        print(f"FAIL - {name}\n       want [{want}] got [{got}]"); failed += 1
def has(name, text, needle):
    eq(name, needle if needle in text else text, needle)

def put(name, text):
    with open(os.path.join(run_dir, name), "w") as f: f.write(text)
def rm(*names):
    for n in names:
        try: os.remove(os.path.join(run_dir, n))
        except FileNotFoundError: pass

class FakeSources:
    names = {}
    def get(self): return self.names
src = FakeSources()
snap = lambda: tray.Snapshot(src)

live = subprocess.Popen(["sleep", "60"])
dead = subprocess.Popen(["true"]); dead.wait()
MIC = "alsa_input.usb-Headset-01.mono-fallback"

print("# icon and tooltip")
rm("listen.pid", "listen.state", "rec.pid", "mic", "roster", "focus-pane")
eq("nothing running is off", snap().color(), "off")
has("off says so", snap().tooltip(), "listener: off")

# A listener killed too hard to clean up leaves its last state behind; it
# must not keep the icon red.
put("listen.pid", str(dead.pid))
put("listen.state", f"pid={dead.pid}\nstate=transmitting\ntarget=alpha\nhealth=ok\nsince=0\n")
eq("a dead listener's state is ignored", snap().color(), "off")

put("listen.pid", str(live.pid))
eq("a state file from another pid is ignored", snap().color(), "ok")
has("an unpublished state still reads as running", snap().tooltip(), "listener: running")

put("listen.state", f"pid={live.pid}\nstate=standby\ntarget=\nhealth=ok\nsince={int(time.time())}\n")
eq("standby is green", snap().color(), "ok")
has("standby says so", snap().tooltip(), "standing by")

put("listen.state", f"pid={live.pid}\nstate=transmitting\ntarget=alpha\nhealth=ok\nsince={int(time.time()) - 5}\n")
eq("an open mic is red", snap().color(), "live")
has("and names who it's open for", snap().tooltip(), "MIC OPEN for alpha (5s)")

put("listen.state", f"pid={live.pid}\nstate=standby\ntarget=\nhealth=silent\nsince=0\n")
eq("a silent mic is amber", snap().color(), "warn")
has("and says why", snap().tooltip(), "mic went silent")
put("listen.state", f"pid={live.pid}\nstate=standby\ntarget=\nhealth=down\nsince=0\n")
eq("a dead stream is amber", snap().color(), "warn")

put("listen.state", f"pid={live.pid}\nstate=standby\ntarget=\nhealth=ok\nsince=0\n")
put("mic", MIC)
src.names = {MIC: "Headset Mono"}
has("the mic is shown by description", snap().tooltip(), "mic: Headset Mono")
src.names = {"alsa_input.other": "Other"}
eq("an unplugged mic is amber", snap().color(), "warn")
has("and says so", snap().tooltip(), "(not connected)")
src.names = {}
eq("no pactl answer is not a warning", snap().color(), "ok")

rm("listen.pid", "listen.state")
put("rec.pid", str(live.pid))
eq("push-to-talk is red with the listener off", snap().color(), "live")
has("and says so", snap().tooltip(), "push-to-talk")
rm("rec.pid")

put("roster", "alpha\t%1\nbravo\t%2\n")
put("focus-pane", "%2")
eq("the roster is read with its focus", snap().roster, [("alpha", False), ("bravo", True)])
has("and listed", snap().tooltip(), "instances: alpha, bravo (focused)")

print("# actions")
notes = []
tray.notify = notes.append
def settle(secs=3):
    loop = GLib.MainLoop()
    GLib.timeout_add(int(secs * 1000), loop.quit)
    def check():
        if notes: loop.quit(); return False
        return True
    GLib.timeout_add(50, check)
    loop.run()

tray.spawn(["sh", "-c", "echo 'no instance charlie' >&2; exit 1"])
settle()
eq("a failed action shows its error", notes, ["no instance charlie"])

notes.clear()
tray.spawn(["true"]); settle(0.5)
eq("a successful action is quiet", notes, [])

# spawn can leave a tmux server holding the child's stderr; that must not
# delay the failure report until the grandchild exits.
notes.clear()
t = time.monotonic()
tray.spawn(["sh", "-c", f"(sleep 5; : {run_dir}) & echo boom >&2; exit 3"])
settle()
eq("a lingering grandchild doesn't hold up the report", (notes, time.monotonic() - t < 2), (["boom"], True))

notes.clear()
tray.spawn([os.path.join(run_dir, "no-such-script")])
eq("a missing script is reported", len(notes) == 1 and "no-such-script" in notes[0], True)

got = []
real_spawn, tray.spawn = tray.spawn, got.append
os.environ["TERMINAL"] = "kitty --single-instance"
tray.terminal("claude-listen", "--log")
eq("$TERMINAL may carry arguments", got, [["kitty", "--single-instance", "-e", "claude-listen", "--log"]])
tray.spawn = real_spawn

live.kill()
print(f"\npassed: {passed}  failed: {failed}")
sys.exit(1 if failed else 0)
PY

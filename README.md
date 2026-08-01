# claude-dictate

Talk to a Claude Code session while your hands are busy.

I built this so I could keep a Claude session moving while gaming — hands on
mouse and keyboard, game owns the focus, but I still want to answer Claude's
questions or queue up the next task. It's a ~150 line bash script: bind it to
a hotkey, press once to record, press again to transcribe and send. The text
lands in a tmux session via `send-keys`, so window focus is never touched and
the game never notices.

## How it works

- First press starts recording the mic with `pw-record`
- Second press stops recording, transcribes locally with whisper.cpp, and
  injects the text into a tmux session named `claude` (plus Enter)
- The hotkey works globally under an X11 window manager because the WM grabs
  the key before the game ever sees it

Claude just runs in tmux: `tmux new -s claude claude`.

## Requirements

- Linux, bash, tmux
- PipeWire's `pw-record` by default — the recorder is configurable, anything
  that writes 16kHz mono s16 wav and stops on SIGTERM works
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and a ggml model
- `notify-send` for desktop notifications (optional — degrades silently)
- An X11 WM or hotkey daemon to bind the script to a key

## Install

Clone and put the script on your PATH:

```sh
git clone https://github.com/orloc/claude-dictate
ln -s "$PWD/claude-dictate/claude-dictate" ~/.local/bin/claude-dictate
```

Build [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (the CUDA build
if you have an nvidia card — see quirks below) and download a model,
e.g. `small.en`.

Then point the script at both in `~/.config/claude-dictate/config` — it's
plain shell, sourced on every run:

```sh
DICTATE_WHISPER="$HOME/dev/whisper.cpp/build/bin/whisper-cli"
DICTATE_MODEL="$HOME/dev/whisper.cpp/models/ggml-small.en.bin"
```

Bind the script to a key. awesome WM:

```lua
awful.key({ modkey }, "F9", function()
    awful.spawn("claude-dictate")
end, { description = "dictate to claude", group = "custom" }),
```

Any hotkey daemon works the same way — sxhkd, xbindkeys, whatever your setup
already has. The script is just a toggle; press it however you like.

## Usage

1. `tmux new -s claude claude`
2. Press the hotkey — recording starts
3. Say the thing
4. Press again — transcribes and sends to the tmux session

A notification shows what was sent so you know it heard you right.

## Config

All env vars, or set them in `~/.config/claude-dictate/config`:

| var | default | what |
|---|---|---|
| `DICTATE_WHISPER` | `whisper-cli` on PATH | whisper-cli binary |
| `DICTATE_MODEL` | none (required) | path to a ggml model |
| `DICTATE_TARGET` | `claude` | tmux session to inject into |
| `DICTATE_RECORDER` | `pw-record --rate 16000 --channels 1 --format s16` | record command; gets the output .wav appended |

## Notes / quirks

- Recordings under ~0.5s are dropped ("heard nothing") — stops accidental
  double-presses from sending garbage.
- Whisper hallucinates on near-silent audio — "you", "thank you", "thanks for
  watching!" — so a short blocklist filters those out too.
- Use the CUDA build of whisper.cpp if you can. On an RTX 4070 with
  `small.en`, a transcription is about 1 second including model load. CPU
  works but the pause is long enough to be annoying mid-game.
- The global-hotkey-over-a-fullscreen-game trick depends on the WM grabbing
  the key before the game does — that's X11 behavior. Only tested there.
- Double-pressing the hotkey won't double-record or double-send — the toggle
  is atomic. A stale pidfile also can't kill some unrelated process that
  recycled the PID.

## Tests

`./tests/run-tests.sh` — plain bash, no frameworks. Fakes the recorder,
whisper, and notifications; injects into a real throwaway tmux session on a
private socket.

## License

MIT

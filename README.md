# claude-dictate

Talk to a Claude Code session while your hands are busy — and have it talk back.

I built this so I could keep a Claude session moving while gaming — hands on
mouse and keyboard, game owns the focus, but I still want to answer Claude's
questions or queue up the next task. It's a ~150 line bash script: bind it to
a hotkey, press once to record, press again to transcribe and send. The text
lands in a tmux session via `send-keys`, so window focus is never touched and
the game never notices.

`claude-speak` closes the loop, reading Claude's replies out loud so you never
have to look at the terminal at all.

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

For speech (all optional — without them `claude-speak` no-ops):

- `python3` and `jq`
- a sherpa-onnx offline-TTS build and a Kokoro model (see Talking back)
- `paplay`, `aplay` or `ffplay` for playback

## Install

Clone and put the script on your PATH:

```sh
git clone https://github.com/orloc/claude-dictate
ln -s "$PWD/claude-dictate/claude-dictate" ~/.local/bin/claude-dictate
```

Voice output (`claude-speak`) and hands-free control (`claude-listen`) are
optional additions on top; see their sections below.

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

## Talking back

`claude-speak` reads Claude's replies aloud with [Kokoro][kokoro] neural TTS,
driven through the [sherpa-onnx][sherpa] offline-TTS CLI. It's wired in via
Claude Code hooks — and not just at the end of a turn: `MessageDisplay` speaks
each assistant message as it appears, so a long working turn narrates itself
(the sentence before each tool call) instead of staying silent until `Stop`.
Utterances queue rather than cut each other off; `Stop` acts as the fallback
for a Claude Code that doesn't emit `MessageDisplay`, with a per-session
ledger making sure nothing is spoken twice.

A response is markdown, and most of markdown is unlistenable — so the text is
reduced before it's spoken: fenced code blocks and tables are dropped, link
text is kept but URLs aren't, long paths collapse to their basename, and
bullets become sentences so the list doesn't run together. Anything past
`SPEAK_MAX_CHARS` is cut with a spoken "response truncated".

Synthesis runs about 2× faster than real time, so rendering a long reply up
front would mean waiting half a minute to hear the first word. Instead the
text is split into chunks and synthesis runs one chunk ahead of playback. The
opening chunk is capped short (90 chars) because nothing is audible until it
finishes — that's what sets time-to-first-word, and it lands around a second,
most of which is model load. Later chunks render while earlier ones play, so
they're allowed to be longer and keep the prosody natural.

Set it up by symlinking both scripts onto your PATH:

```sh
ln -s "$PWD/claude-dictate/claude-speak"      ~/.local/bin/claude-speak
ln -s "$PWD/claude-dictate/claude-speak-hook" ~/.local/bin/claude-speak-hook
```

then adding the hooks to `~/.claude/settings.json` — all three events route
through `claude-speak-hook`, which is what session-gates them (a bare
`claude-speak --stop` on UserPromptSubmit would let a prompt typed in any
session on the machine cut off the dictation session mid-word):

```json
{
  "hooks": {
    "MessageDisplay": [
      { "hooks": [{ "type": "command", "command": "claude-speak-hook", "timeout": 10 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "claude-speak-hook", "timeout": 10 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "claude-speak-hook", "timeout": 5 }] }
    ]
  }
}
```

The engine and voice default to the assets [99dps][99dps] downloads for its
combat cues (`~/.cache/99dps/tts`), since that's ~120MB there's no reason to
keep twice. Point `SPEAK_ENGINE`/`SPEAK_MODEL_DIR` elsewhere if you'd rather
install them standalone; with neither present, `claude-speak` silently no-ops.

Two details worth knowing:

- **It only speaks for the dictation session.** A user-level hook fires for
  every Claude Code session on the machine, which would mean your work
  terminals talking at you. The hook checks the tmux session name against
  `DICTATE_TARGET` and stays silent anywhere else.
- **Speech is interruptible.** Playback runs detached in its own process
  group; `claude-speak --stop` kills it mid-word. That's wired to two things —
  submitting a prompt (the `UserPromptSubmit` hook) and starting a recording,
  so pressing the dictate hotkey while Claude is mid-sentence shuts it up
  before the mic opens rather than recording your own speakers.
- **It answers through the headset you're talking into.** The reply would
  otherwise go to the system default sink, which is a different device than
  the pinned mic as often as not. The capture and playback nodes of one card
  share a name stem, so the mic named in `DICTATE_RECORDER --target` picks the
  sink to answer through — no second thing to configure, and no changing your
  system defaults. `SPEAK_SINK` overrides it, and if the pinned sink is gone
  (headset powered off) playback falls back to the default device rather than
  going silent.

[kokoro]: https://huggingface.co/hexgrad/Kokoro-82M
[sherpa]: https://github.com/k2-fsa/sherpa-onnx
[99dps]: https://github.com/orloc/99dps

## Hands free

`claude-listen` drops the hotkey entirely. The mic is always open, but nothing
reaches Claude until you key up — a radio channel, not a dictaphone:

```
"skylark, come in"            open the mic
 ...say your thing...
"... skylark, out"            send it
"... skylark, disregard"      throw it away
"skylark, silence"            stop a reply being read aloud
"skylark, radio check"        hear the current state
"skylark, help"               hear the protocol, spoken
"skylark, help basics"        the dictation commands, in detail
"skylark, help instances"     addressing instances by name
"skylark, help management"    spawn, list, kill, rename, reap, status
```

The commands that aim at a name take it on either side of the verb — `"focus
bravo"` and `"bravo, focus"` are the same instruction, as are `come in` and
`silence`. The two closing commands are deliberately one-way: `out` and
`disregard` are the only prowords that match at the *end* of speech carrying
dictated content, so the leading name is what stops a sentence trailing off in
"...out" from sending your transmission.

Help is a menu rather than a monologue. Spoken, the full command set ran about
a minute, and audio is the one medium you cannot skim — so `"skylark, help"`
gives you the four commands you need to talk at all plus the names of the
pages, and each page is a handful of short sentences. The top level asks the
roster first: with nothing spawned it says nothing about instances. An
unrecognized page is not a command at all, which is what keeps `"skylark, help
me move this"` from firing anything.

**Turning it on and off.** The listener is a background process you toggle,
not something that runs forever:

```sh
claude-listen --toggle    # on, or off if already on — bind this to a key
claude-listen --start     # on
claude-listen --stop      # off
claude-listen --status    # which is it
claude-listen             # foreground, logging to stderr (for debugging)
```

Toggling is deliberately the primary verb, because the thing you want bound to
a key is "start listening / stop listening" — a rising three-tone says it's
live, a falling three-tone says it's off, so you know without looking. Under
awesome:

```lua
awful.key({ modkey, "Shift" }, "d", function()
    awful.spawn(os.getenv("HOME") .. "/.local/bin/claude-listen --toggle")
end, { description = "toggle claude voice listener", group = "hotkeys" }),
```

That leaves the plain `claude-dictate` hotkey alone, so push-to-talk stays
available for when you'd rather not have an open mic.

**Why it doesn't misfire.** Safety comes from *position*, not from picking a
rare word — any word you choose you will eventually say. A standalone command
must be the **entire** utterance, so "then skylark comes in later" can't fire
it, and the closing commands must be the **final** words of a transmission,
with the callsign attached, so "move the loop out" doesn't send. That also
means there's no escape hatch to learn: you can talk about the commands as
much as you like. The test suite is mostly these near-misses.

Two structural consequences worth knowing. While the mic is open **everything
is dictation** — "skylark, help" mid-transmission is typed, not run, because
inside a transmission only the closing commands exist. And a transmission you
forget to close sends itself rather than being lost.

`LISTEN_MAX_TX` is how much **quiet** ends it — 30 seconds of nobody saying
anything, by default. It deliberately measures silence rather than length: an
open mic that closes on its own after N seconds of speech interrupts you
mid-thought, and the interruption is worse than it sounds, because everything
you say after the cut arrives in standby, where anything that isn't a command
is discarded. Speak as long as you like; pauses shorter than `LISTEN_MAX_TX`
keep the channel yours.

Treat that number as a blast radius rather than a convenience. An open mic
dictates whatever is audible, so a transmission you walked away from ships the
room — a conversation, a phone call, whoever else is talking. Quiet can't catch
that case (a room that keeps talking never goes quiet), which is what
`LISTEN_MAX_TX_TOTAL` is for: a hard ceiling on one transmission however much
is said into it, default 15 minutes, `0` to disable. It sits far above any real
dictation so it only ever catches a runaway.

**Feedback is tonal, not spoken** — rising two-tone for open, falling for
close, a descending triple for discard, a low buzz for a command that made no
sense. You hear these constantly and you're not looking at the screen, so
words would wear out fast.

Desktop notifications carry the same states for when you *are* looking: mic
opened, the transmission echoed back as it builds so you can see it heard you
right, what was finally sent, discards, and errors. They describe one changing
thing, so each replaces the last in place rather than stacking a column of
stale state — the id comes from the daemon rather than being hardcoded, so it
can't collide with another app's notification.

Speech is found by energy against a *rolling* estimate of the noise floor
rather than a fixed threshold, since mic gain and room noise move around; the
floor only learns from quiet frames, so a long sentence can't drag it up over
itself. `LISTEN_MARGIN_DB` and `LISTEN_CLOSE_MS` are the knobs if it clips your
first word or splits sentences at pauses.

### Which mic

A headset is often more than one audio device. A wireless one is usually two:
the dongle is a card, and the headset's own USB audio is a second card that
appears the moment you plug the charging cable in. Which one carries your voice
depends on how it's connected right now.

The trap is that the losing device doesn't fail. A dongle with no headset behind
it stays enumerated and streams perfect digital silence, so a config pinned to
it goes quietly deaf rather than erroring — and a mic recording nothing looks
exactly like a room where nobody is talking. Whisper obligingly fills the gap by
hallucinating "Thank you" onto the silence, which is what a dead mic looks like
in the log.

So `claude-mic` picks the device by measurement, not by name:

```sh
claude-mic --show      # what each candidate measured, and the answer
claude-mic --resolve    # just the answer
```

It records a moment from each candidate and takes the first whose samples
aren't all zero — a live converter's quietest room still has noise in the last
bit, so no threshold needs tuning. Point `DICTATE_RECORDER` at it and the
device is chosen afresh every time recording starts:

```sh
DICTATE_MIC_MATCH="Corsair"
DICTATE_RECORDER="$HOME/dev/claude-dictate/claude-mic --record --rate 16000 --channels 1 --format s16"
```

`DICTATE_MIC_MATCH` matters more than it looks: without it the first *live*
source wins, and an S/PDIF input carrying nothing still reads as live, since an
unlocked receiver emits non-zero dither. Name the card you mean.

The answer is cached, keyed on the candidate list itself — so the hotkey path
pays nothing (a probe before the mic opens would clip your first word), while
plugging a cable in or pulling a dongle out invalidates it, because that is
exactly when the answer changes. `claude-mic` publishes what it picked, and
`claude-speak` reads it to choose the sink on the same card: replies come out
of the headset you're talking into, wherever that is this minute.

Switching mid-session heals itself. The segmenter reports a stream that has
been exactly zero for `LISTEN_DEAD_MS`, and the listener drops the cached
device and rebuilds on whatever is live now — the only place that distinction
can be made is where the samples are.

The honest caveat: this means something is always listening on your mic.
Everything stays on the machine — whisper is local and nothing is transmitted
unless it's a command or a dictated message — but "always on" is a real change
from a hotkey, and worth deciding deliberately rather than by default.

## Config

All env vars, or set them in `~/.config/claude-dictate/config` (all three
scripts read the same file):

| var | default | what |
|---|---|---|
| `DICTATE_WHISPER` | `whisper-cli` on PATH | whisper-cli binary |
| `DICTATE_MODEL` | none (required) | path to a ggml model |
| `DICTATE_TARGET` | `claude` | tmux session to inject into, and the only one spoken to |
| `DICTATE_RECORDER` | `pw-record --rate 16000 --channels 1 --format s16` | record command; gets the output .wav appended |
| `DICTATE_SUBMIT_DELAY` | `0.5` | pause between the text and the Enter that submits it |
| `SPEAK_ENABLED` | `1` | `0` mutes speech entirely |
| `SPEAK_ENGINE` | 99dps cache | `sherpa-onnx-offline-tts` binary |
| `SPEAK_MODEL_DIR` | 99dps cache | Kokoro model directory |
| `SPEAK_SID` | `1` (af_bella) | voice index, 0–10 |
| `SPEAK_LENGTH_SCALE` | `0.85` | larger is slower; below ~0.8 gets mushy |
| `SPEAK_MAX_CHARS` | `1200` | cap before the reply is truncated |
| `SPEAK_SINK` | the mic's card | output sink to play through |
| `LISTEN_CALLSIGN` | `skylark` | the callsign every command carries |
| `LISTEN_ALIASES` | `sky lark;skylar;sky clark` | `;`-separated spellings whisper might produce instead |
| `LISTEN_MAX_TX` | `30` | seconds of quiet that close an unkeyed transmission |
| `LISTEN_MAX_TX_TOTAL` | `900` | hard ceiling on one transmission, `0` disables |
| `LISTEN_MARGIN_DB` | `12` | dB above the noise floor that counts as speech |
| `LISTEN_CLOSE_MS` | `700` | silence that ends an utterance |
| `LISTEN_DEAD_MS` | `20000` | digitally silent capture that means the device is gone |
| `DICTATE_MIC_MATCH` | any capture source | extended regex `claude-mic` requires of a source name |
| `DICTATE_MIC_PROBE_MS` | `400` | how long `claude-mic` samples each candidate |

## Notes / quirks

- Recordings under ~0.5s are dropped ("heard nothing") — stops accidental
  double-presses from sending garbage.
- **The Enter that submits a transcript must be its own keystroke, sent after
  a pause.** Chained onto the text in one `tmux send-keys` call, both land in
  a single read and the TUI swallows the newline into the text it's still
  ingesting — the transcript sits in the prompt box, dictated but never sent.
  Measured against a live session: chained never submits, a 0.4s gap always
  does. `DICTATE_SUBMIT_DELAY` (0.5s) is the gap; raise it if submits still
  get missed on a slower box.
- `pw-record` follows the *default* PipeWire source, which is not necessarily
  a microphone — on my box it was the USB interface's S/PDIF input, and every
  recording came back as silence that whisper dutifully hallucinated a "you"
  onto. If dictation reports "heard nothing" every time, check the level of
  `$XDG_RUNTIME_DIR/claude-dictate/rec.wav` before suspecting whisper, and pin
  the mic with `--target` in `DICTATE_RECORDER`.
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

`./tests/run-speak-tests.sh` — same style for the speech side. A fake sherpa
CLI logs the text it was asked to synthesize, so the assertions are about what
would actually be spoken rather than about the cleaning regexes in isolation.

`./tests/run-listen-tests.sh` — grammar and state machine. It sources the
script and replaces every side effect, so a whole session can be driven with
no microphone, and so the tests can assert what was *not* done: that ordinary
speech never dictates, that near-miss sentences never fire a command, and that
help never reaches the dictation path. The singleton tests run real background
instances on fake binaries.

`./tests/run-mic-tests.sh` — device resolution against fake `pactl` and
`pw-record`, so a headset can be plugged, unplugged and moved between its
dongle and its cable with no audio hardware in the room. The fakes carry the
distinction the real bug turned on: `FAKE_SOURCES` is what gets *listed*,
`FAKE_LIVE` is what actually carries sound, and the losing device stays listed.

`./tests/run-hook-tests.sh` — the speak hook end to end: payloads in, spoken
text and `--stop` calls out, with a fake tmux deciding which session the hook
thinks it's in. Mostly gating and dedup: wrong sessions stay silent, a repeat
message id is spoken once, an identical *later* reply is still spoken, and
Stop keeps quiet when MessageDisplay already narrated the turn.

## License

MIT

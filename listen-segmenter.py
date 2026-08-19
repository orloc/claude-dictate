#!/usr/bin/env python3
"""Cut a live mic stream into utterances and write each one as a wav.

Reads raw 16 kHz mono s16 on stdin (what `pw-record --format s16` emits) and
prints one wav path per line as each utterance closes, so the caller can
transcribe them as they arrive.

Speech is found by energy against a rolling estimate of the room's noise
floor rather than a fixed threshold: mic gain, headset position and fan noise
all move the floor, and a fixed number would need retuning every session. The
floor only tracks downward quickly (a quiet frame is evidence about silence);
it rises slowly, so a long sentence can't drag the floor up over itself.

Hysteresis matters as much as the threshold. Opening needs several consecutive
loud frames so a keyboard clack can't start an utterance, and closing needs a
long run of quiet so a pause for breath mid-sentence doesn't split it in two.
"""

import argparse
import array
import math
import os
import sys
import wave

RATE = 16000
FRAME_MS = 20
FRAME_SAMPLES = RATE * FRAME_MS // 1000
FRAME_BYTES = FRAME_SAMPLES * 2


def dbfs(frame):
    """RMS of one frame in dBFS. Silence floors at -100 rather than -inf."""
    if not frame:
        return -100.0
    acc = 0
    for s in frame:
        acc += s * s
    rms = math.sqrt(acc / len(frame)) / 32768.0
    return 20 * math.log10(rms) if rms > 1e-9 else -100.0


def skip_header(stream):
    """Consume any container header, returning bytes that are already audio.

    pw-record writing to stdout emits a 24-byte AU header (little-endian magic,
    so it reads as "dns." rather than ".snd"); other recorders emit RIFF/WAVE
    or nothing at all. Guessing wrong costs a fraction of a frame, but parsing
    it properly keeps a header out of the first level measurement.
    """
    head = stream.read(4)
    if len(head) < 4:
        return b""

    if head in (b".snd", b"dns."):
        raw = stream.read(4)
        for order in ("big", "little"):
            offset = int.from_bytes(raw, order)
            if 8 <= offset <= 4096:
                stream.read(offset - 8)
                return b""
        return b""

    if head == b"RIFF":
        stream.read(8)  # size + "WAVE"
        while True:
            cid = stream.read(4)
            if len(cid) < 4:
                return b""
            size = int.from_bytes(stream.read(4), "little")
            if cid == b"data":
                return b""
            stream.read(size + (size & 1))

    return head  # headerless stream — those bytes are samples


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--open-frames", type=int, default=4,
                    help="consecutive loud frames needed to start an utterance")
    ap.add_argument("--close-ms", type=int, default=700,
                    help="silence needed to end an utterance")
    ap.add_argument("--margin-db", type=float, default=12.0,
                    help="how far above the noise floor counts as speech")
    ap.add_argument("--max-ms", type=int, default=90000,
                    help="hard cap on one utterance, so a stuck-open mic ends")
    ap.add_argument("--min-ms", type=int, default=300,
                    help="drop utterances shorter than this as noise")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    close_frames = max(1, args.close_ms // FRAME_MS)
    max_frames = max(1, args.max_ms // FRAME_MS)
    min_frames = max(1, args.min_ms // FRAME_MS)

    floor = -60.0          # rolling noise-floor estimate, seeded pessimistically
    loud_run = 0
    quiet_run = 0
    speaking = False
    buf = []
    # a little audio from before the trigger, so the first phoneme survives
    preroll = []
    preroll_max = args.open_frames + 5
    seq = 0

    stdin = sys.stdin.buffer
    pending = skip_header(stdin)
    while True:
        need = FRAME_BYTES - len(pending)
        raw, pending = pending + stdin.read(need), b""
        if len(raw) < FRAME_BYTES:
            break
        frame = array.array("h")
        frame.frombytes(raw)
        level = dbfs(frame)

        loud = level > floor + args.margin_db

        # Track the floor only on quiet frames, and only downward fast. Speech
        # frames must never teach the estimator what silence sounds like.
        if not loud:
            floor = min(floor + 0.02, level) if level < floor else floor + 0.02
            floor = max(floor, -100.0)

        if not speaking:
            preroll.append(raw)
            if len(preroll) > preroll_max:
                preroll.pop(0)
            loud_run = loud_run + 1 if loud else 0
            if loud_run >= args.open_frames:
                speaking = True
                buf = list(preroll)
                preroll = []
                quiet_run = 0
        else:
            buf.append(raw)
            quiet_run = 0 if loud else quiet_run + 1
            if quiet_run >= close_frames or len(buf) >= max_frames:
                # trailing silence is not worth transcribing
                keep = buf[: len(buf) - quiet_run] if quiet_run < len(buf) else buf
                speaking = False
                loud_run = 0
                if len(keep) >= min_frames:
                    seq += 1
                    path = os.path.join(args.outdir, f"utt-{seq:06d}.wav")
                    with wave.open(path, "wb") as w:
                        w.setnchannels(1)
                        w.setsampwidth(2)
                        w.setframerate(RATE)
                        w.writeframes(b"".join(keep))
                    print(path, flush=True)
                buf = []


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass

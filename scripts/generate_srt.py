#!/usr/bin/env python3
import sys
import os
from faster_whisper import WhisperModel

def format_ts(seconds: float) -> str:
    ms = int(round(seconds * 1000))
    hrs = ms // 3_600_000
    ms %= 3_600_000
    mins = ms // 60_000
    ms %= 60_000
    secs = ms // 1_000
    ms %= 1_000
    return f"{hrs:02d}:{mins:02d}:{secs:02d},{ms:03d}"

def main():
    if len(sys.argv) < 2:
        print("Usage: generate_srt.py <VID_ID>", file=sys.stderr)
        sys.exit(1)

    vid_id = sys.argv[1]
    workdir = f"/tmp/faceless_pipeline/{vid_id}"
    wav_path = os.path.join(workdir, "narration_master.wav")
    srt_path = os.path.join(workdir, "captions.srt")

    if not os.path.exists(wav_path):
        print(f"Error: {wav_path} not found", file=sys.stderr)
        sys.exit(1)

    model = WhisperModel("base.en", device="cpu", compute_type="int8")
    segments, _ = model.transcribe(wav_path, word_timestamps=True)

    words = []
    for seg in segments:
        if seg.words:
            words.extend(seg.words)

    chunk_size = 4
    srt_lines = []
    idx = 1
    for i in range(0, len(words), chunk_size):
        chunk = words[i:i + chunk_size]
        start_ts = format_ts(chunk[0].start)
        end_ts = format_ts(chunk[-1].end)
        text = " ".join(w.word.strip() for w in chunk).upper()
        srt_lines.append(f"{idx}\n{start_ts} --> {end_ts}\n{text}\n")
        idx += 1

    srt_content = "\n".join(srt_lines)
    with open(srt_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(srt_content)

    print(srt_content)

if __name__ == "__main__":
    main()


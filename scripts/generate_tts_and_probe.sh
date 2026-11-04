#!/bin/sh
# Usage: /home/node/scripts/generate_tts_and_probe.sh <VID_ID> <SCENE_ID> <TEXT_FILE_PATH>
set -e

VID_ID="$1"
SCENE_ID="$2"
TEXT_FILE="$3"
VOICE="${TTS_VOICE:-en-US-ChristopherNeural}"
RATE="${TTS_RATE:-+3%}"

WORKDIR="/tmp/faceless_pipeline/${VID_ID}"
mkdir -p "$WORKDIR"

OUT_MP3="${WORKDIR}/${SCENE_ID}_vo.mp3"

# Strip any stray CR characters from input text file
tr -d '\r' < "$TEXT_FILE" > "${TEXT_FILE}.clean"

# Generate neural voiceover using free edge-tts CLI
edge-tts \
  --voice "$VOICE" \
  --rate="$RATE" \
  --file "${TEXT_FILE}.clean" \
  --write-media "$OUT_MP3"

DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT_MP3")

# Check if duration is between 7.5s and 11.5s for clean 10s Flow clip time-stretching
FLAG=$(awk -v d="$DURATION" 'BEGIN { if (d < 7.5 || d > 11.5) print "REWRITE_NEEDED"; else print "OK" }')

printf '{"video_id":"%s","scene_id":"%s","mp3_path":"%s","duration":%.2f,"flag":"%s"}\n' \
  "$VID_ID" "$SCENE_ID" "$OUT_MP3" "$DURATION" "$FLAG"


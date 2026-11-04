#!/bin/sh
# Usage: /home/node/scripts/assemble_draft.sh <VID_ID> <EXPECTED_SCENES>
set -e

VID_ID="$1"
EXPECTED="$2"
WORKDIR="/tmp/faceless_pipeline/${VID_ID}"
cd "$WORKDIR"

CLIP_COUNT=$(ls -1 S*_clip.mp4 2>/dev/null | wc -l | tr -d ' ')
VO_COUNT=$(ls -1 S*_vo.mp3 2>/dev/null | wc -l | tr -d ' ')

if [ "$CLIP_COUNT" -ne "$EXPECTED" ] || [ "$VO_COUNT" -ne "$EXPECTED" ]; then
  printf '{"status":"ERROR","message":"Asset mismatch: expected %s scenes, found %s clips and %s voiceovers"}\n' \
    "$EXPECTED" "$CLIP_COUNT" "$VO_COUNT"
  exit 1
fi

rm -f concat_list.txt
for vo_file in $(ls S*_vo.mp3 | sort); do
  scene_prefix="${vo_file%_vo.mp3}"
  clip_file="${scene_prefix}_clip.mp4"

  vo_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$vo_file")
  clip_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$clip_file")

  # Calculate PTS multiplier so video duration equals (vo_dur + 0.20s pause)
  pts_factor=$(awk -v v="$vo_dur" -v c="$clip_dur" 'BEGIN { printf "%.4f", (v + 0.20) / c }')

  ffmpeg -y -loglevel error -i "$clip_file" -i "$vo_file" \
    -filter_complex "[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,setpts=${pts_factor}*PTS,fps=30,format=yuv420p[v];[1:a]apad=pad_dur=0.20[a]" \
    -map "[v]" -map "[a]" -c:v libx264 -preset fast -crf 20 -c:a aac -b:a 192k "${scene_prefix}_synced.mp4"

  echo "file '${scene_prefix}_synced.mp4'" >> concat_list.txt
done

# Concatenate all synced scenes
ffmpeg -y -loglevel error -f concat -safe 0 -i concat_list.txt -c copy merged_scenes.mp4

# Extract clean narration track for Whisper transcription
ffmpeg -y -loglevel error -i merged_scenes.mp4 -vn -acodec pcm_s16le -ar 16000 -ac 1 narration_master.wav

# Mix background music (-18dB) with 2s fade-out and loudness normalization (-14 LUFS)
total_dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 merged_scenes.mp4)
fade_start=$(awk -v t="$total_dur" 'BEGIN { printf "%.2f", (t > 2.5 ? t - 2.0 : 0) }')

if [ -f "bg_music.mp3" ]; then
  ffmpeg -y -loglevel error -i merged_scenes.mp4 -stream_loop -1 -i bg_music.mp3 \
    -filter_complex "[1:a]volume=0.12,afade=t=out:st=${fade_start}:d=2[bgm];[0:a][bgm]amix=inputs=2:duration=first:dropout_transition=2,loudnorm=I=-14:TP=-1.5:LRA=11[aout]" \
    -map 0:v -map "[aout]" -c:v copy -c:a aac -b:a 192k "${VID_ID}_draft.mp4"
else
  cp merged_scenes.mp4 "${VID_ID}_draft.mp4"
fi

printf '{"status":"OK","draft_path":"%s/%s_draft.mp4","duration":%.2f}\n' "$WORKDIR" "$VID_ID" "$total_dur"


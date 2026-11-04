#!/bin/sh
# Usage: /home/node/scripts/burn_subtitles.sh <VID_ID>
set -e

VID_ID="$1"
WORKDIR="/tmp/faceless_pipeline/${VID_ID}"
cd "$WORKDIR"

# Ensure SRT has clean LF endings if edited from Google Sheets on Windows
tr -d '\r' < approved_captions.srt > approved_captions_clean.srt

ffmpeg -y -loglevel error -i "${VID_ID}_draft.mp4" \
  -vf "subtitles=approved_captions_clean.srt:force_style='FontName=DejaVu Sans,FontSize=13,Bold=1,PrimaryColour=&H0000FFFF,OutlineColour=&H00000000,BorderStyle=1,Outline=2,Shadow=1,Alignment=2,MarginV=75'" \
  -c:v libx264 -preset fast -crf 19 -c:a copy "${VID_ID}_final.mp4"

printf '{"status":"OK","final_path":"%s/%s_final.mp4"}\n' "$WORKDIR" "$VID_ID"


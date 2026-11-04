


      - TTS_RATE=${TTS_RATE:-+3%}
    volumes:
      - n8n_data:/home/node/.n8n
      - ./tmp_media:/tmp/faceless_pipeline

volumes:
  n8n_data:
```

#### \[NEW\] `.env.example`

```env
# Timezone
GENERIC_TIMEZONE=Asia/Colombo

# Free Neural TTS Configuration (edge-tts)
# Popular faceless voices: en-US-ChristopherNeural, en-US-AndrewMultilingualNeural, en-US-BrianMultilingualNeural, en-GB-RyanNeural
TTS_VOICE=en-US-ChristopherNeural
TTS_RATE=+3%

# Google Workspace IDs (Copy from your browser URL bars)
PRODUCTION_SHEET_ID=your_google_sheet_id_here
DRIVE_ROOT_FOLDER_ID=your_faceless_factory_folder_id
DRIVE_SOURCES_FOLDER_ID=your_01_sources_folder_id
DRIVE_KEYFRAMES_FOLDER_ID=your_02_keyframes_folder_id
DRIVE_CLIPS_FOLDER_ID=your_03_clips_folder_id
DRIVE_AUDIO_FOLDER_ID=your_04_audio_folder_id
DRIVE_RENDERS_FOLDER_ID=your_05_renders_folder_id

# Google AI Studio Key (Free tier for Stage H Metadata generation)
GEMINI_API_KEY=your_ai_studio_api_key

# Meta Graph API (For Facebook Reels Publishing)
META_PAGE_ID=your_facebook_page_id
META_PAGE_ACCESS_TOKEN=your_long_lived_page_access_token
```

### 2. Google Sheets Schema Alignment (`Production_Tracker`)

Verify your existing Google Sheet matches these exact tab and column names so n8n's Google Sheets nodes map fields deterministically.

#### \[NEW\] `schemas/sheets_schema.md`

* **Tab 1: `Videos`**
  * Columns: `Video_ID` | `Topic` | `Status` | `Expected_Scenes` | `Subtitles_SRT` | `YT_Title` | `YT_Description` | `YT_Tags` | `FB_Caption` | `Publish_At` | `YT_URL` | `FB_URL` | `Error_Log`
  * Valid `Status` State Machine Values:
    1. `DRAFTING` (Initial state in Gemini Notebook)
    2. `SCRIPT_APPROVED` (**HITL 2 Trigger** $\rightarrow$ Starts n8n Workflow 1: Free Neural Voiceover Synthesis)
    3. `VO_READY` (Set by n8n once `edge-tts` MP3s and durations are written to Sheet)
    4. `ASSETS_READY` (**HITL 3 Trigger** $\rightarrow$ Starts n8n Workflow 2: Draft Assembly & SRT Transcription)
    5. `REVIEW_DRAFT` (Set by n8n once `<Video_ID>_draft.mp4` and `Subtitles_SRT` are ready)
    6. `RENDER_FINAL` (**HITL 4 Trigger** $\rightarrow$ Starts n8n Workflow 3: Subtitle Burn-In & Metadata Generation)
    7. `REVIEW_METADATA` (Set by n8n once `<Video_ID>_final.mp4` and YT/FB metadata are populated)
    8. `APPROVED_TO_PUBLISH` (**HITL 5 Trigger** $\rightarrow$ Starts n8n Workflow 4: YouTube & Facebook API Upload)
    9. `PUBLISHED` (Final state)
* **Tab 2: `Scenes`**
  * Columns: `Video_ID` | `Scene_ID` | `Narration_Text` | `Source_Citation` | `Fact_Check_Quote` | `Start_Frame_Prompt` | `End_Frame_Prompt` | `Flow_Motion_Prompt` | `SFX_Cue` | `Audio_Duration` | `Duration_Flag`

### 3. Container Media Processing & Subtitle Scripts (`scripts/`)

These scripts live in `./scripts/` on your Windows 10 project folder and are automatically converted to Unix LF and baked into `/home/node/scripts/` inside the n8n container.

#### \[NEW\] `scripts/generate_tts_and_probe.sh`

Synthesizes neural voiceover audio directly inside the container using `edge-tts` (zero API keys required), measures exact audio duration with `ffprobe`, and flags any clip outside the $7.5\text{s}$–$11.5\text{s}$ window.

```sh
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
```

#### \[NEW\] `scripts/assemble_draft.sh`

Validates asset completeness, time-stretches each 9:16 Google Flow clip to match its voiceover duration plus a $0.20\text{s}$ breath pause, concatenates all segments, ducks `bg_music.mp3` at $-18\text{ dB}$, and normalizes output to $-14\text{ LUFS}$.

```sh
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
```

#### \[NEW\] `scripts/generate_srt.py`

Generates 3-to-4-word high-retention vertical captions from `narration_master.wav` using `faster-whisper` and writes `captions.srt`.

```python
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
    vid_id = sys.argv[1]
    workdir = f"/tmp/faceless_pipeline/{vid_id}"
    wav_path = os.path.join(workdir, "narration_master.wav")
    srt_path = os.path.join(workdir, "captions.srt")

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
```

#### \[NEW\] `scripts/burn_subtitles.sh`

Reads the human-reviewed SRT from `/tmp/faceless_pipeline/<VID_ID>/approved_captions.srt` and burns high-contrast yellow/white captions into `<VID_ID>_final.mp4`.

```sh
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
```

### 4. Local n8n Workflows Specification (`workflows/`)

Create four modular workflows inside n8n (or have Antigravity generate and import their JSON definitions into `/home/node/.n8n`).

#### \[NEW\] `workflows/01_stage_f_voiceover_pipeline.json`

* **Trigger:** `Schedule Trigger` (polls every 2 minutes) $\rightarrow$ `Google Sheets: Get Rows` (`Videos` tab where `Status == SCRIPT_APPROVED`).
* **Node 2 (`Google Sheets: Get Scene Rows`):** Filters `Scenes` tab by `Video_ID`.
* **Node 3 (`Loop Over Items`):** Iterates through each scene row (`S01`–`S08`).
* **Node 4 (`Execute Command: Synthesize Free Neural TTS & Probe`):**
  * Safely writes `$json.Narration_Text` to a temporary text file and invokes `edge-tts` via `generate_tts_and_probe.sh`:
    ```sh
    mkdir -p /tmp/faceless_pipeline/{{ $json.Video_ID }} && \
    cat << 'EOF' > /tmp/faceless_pipeline/{{ $json.Video_ID }}/{{ $json.Scene_ID }}.txt
    {{ $json.Narration_Text }}
    EOF
    /home/node/scripts/generate_tts_and_probe.sh "{{ $json.Video_ID }}" "{{ $json.Scene_ID }}" "/tmp/faceless_pipeline/{{ $json.Video_ID }}/{{ $json.Scene_ID }}.txt"
    ```
* **Node 5 (`Google Drive: Upload File`):** Uploads `/tmp/faceless_pipeline/{{ $json.Video_ID }}/{{ $json.Scene_ID }}_vo.mp3` to `/04_Audio`.
* **Node 6 (`Google Sheets: Update Scene Row`):** Parses the JSON stdout from Node 4 and writes `duration` to `Audio_Duration` and `flag` (`OK` or `REWRITE_NEEDED`) to `Duration_Flag`.
* **Node 7 (`Google Sheets: Update Video Status`):** Updates `Videos!Status` to `VO_READY`.

#### \[NEW\] `workflows/02_stage_g_draft_assembly.json`

* **Trigger:** `Schedule Trigger` (every 2 minutes) $\rightarrow$ `Google Sheets: Get Rows` (`Videos` tab where `Status == ASSETS_READY`).
* **Node 2 (`Google Drive: Search & Download`):** Downloads all `S*_clip.mp4` from `/03_Clips` and `S*_vo.mp3` + `bg_music.mp3` from `/04_Audio` into `/tmp/faceless_pipeline/{{ $json.Video_ID }}/`.
* **Node 3 (`Execute Command: Assemble Draft`):** Runs `/home/node/scripts/assemble_draft.sh {{ $json.Video_ID }} {{ $json.Expected_Scenes }}`.
  * *Error Branch:* If exit code $\neq 0$, updates `Videos!Status = ERROR_MISSING_ASSETS` and writes stdout to `Videos!Error_Log`.
* **Node 4 (`Execute Command: Generate SRT`):** Runs `python3 /home/node/scripts/generate_srt.py {{ $json.Video_ID }}`.
* **Node 5 (`Google Drive: Upload Draft`):** Uploads `/tmp/faceless_pipeline/{{ $json.Video_ID }}/{{ $json.Video_ID }}_draft.mp4` to `/05_Renders`.
* **Node 6 (`Google Sheets: Update Draft & SRT`):** Writes `{{$node["Execute Command: Generate SRT"].json["stdout"]}}` into `Videos!Subtitles_SRT` and updates `Videos!Status = REVIEW_DRAFT`.

#### \[NEW\] `workflows/03_stage_g_h_final_render_and_metadata.json`

* **Trigger:** `Schedule Trigger` (every 2 minutes) $\rightarrow$ `Google Sheets: Get Rows` (`Videos` tab where `Status == RENDER_FINAL`).
* **Node 2 (`Execute Command: Write Approved SRT & Burn Subtitles`):**
  * Writes `{{ $json.Subtitles_SRT }}` to `/tmp/faceless_pipeline/{{ $json.Video_ID }}/approved_captions.srt`.
  * Executes `/home/node/scripts/burn_subtitles.sh {{ $json.Video_ID }}`.
* **Node 3 (`Google Drive: Upload Final MP4`):** Uploads `/tmp/faceless_pipeline/{{ $json.Video_ID }}/{{ $json.Video_ID }}_final.mp4` to `/05_Renders`.
* **Node 4 (`Google Sheets: Fetch Scene Citations`):** Aggregates all `Narration_Text` and `Source_Citation` rows for `Video_ID`.
* **Node 5 (`HTTP Request: Gemini Metadata Generator`):** Calls `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key={{ $env.GEMINI_API_KEY }}` with `responseMimeType: "application/json"` to generate `yt_title`, `yt_description` (with verified source citations), `yt_tags`, and `fb_caption`.
* **Node 6 (`Google Sheets: Save Metadata`):** Updates `YT_Title`, `YT_Description`, `YT_Tags`, `FB_Caption`, and sets `Videos!Status = REVIEW_METADATA`.

#### \[NEW\] `workflows/04_stage_h_multiplatform_publisher.json`

* **Trigger:** `Schedule Trigger` (every 5 minutes) $\rightarrow$ `Google Sheets: Get Rows` (`Videos` tab where `Status == APPROVED_TO_PUBLISH`).
* **Node 2 (`HTTP Request: YouTube Resumable Upload Init`):**
  * **Method:** `POST`
  * **URL:** `https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status`
  * **Body:**
    ```json
    {
      "snippet": {
        "title": "{{ $json.YT_Title }}",
        "description": "{{ $json.YT_Description }}",
        "tags": "{{ $json.YT_Tags.split(',') }}",
        "categoryId": "27"
      },
      "status": {
        "privacyStatus": "private",
        "publishAt": "{{ $json.Publish_At }}",
        "selfDeclaredMadeForKids": false
      }
    }
    ```
* **Node 3 (`HTTP Request: YouTube Binary Put`):** Sends `/tmp/faceless_pipeline/{{ $json.Video_ID }}/{{ $json.Video_ID }}_final.mp4` to the `Location` header returned by Node 2 (`Retry On Fail = true`, `Max Tries = 3`, `Wait Between Tries = 5000ms`).
* **Node 4 (`HTTP Request: Meta Graph API Reels Publish`):**
  * Step 4a: `POST https://graph.facebook.com/v21.0/{{ $env.META_PAGE_ID }}/video_reels` (`upload_phase=start`)
  * Step 4b: Binary upload to `upload_url`
  * Step 4c: `POST` (`upload_phase=finish`, `video_state=SCHEDULED`, `scheduled_publish_time={{ $json.Publish_At_Unix }}`, `description={{ $json.FB_Caption }}`)
* **Node 5 (`Google Sheets: Mark Published`):** Writes `YT_URL`, `FB_URL`, and sets `Videos!Status = PUBLISHED`.

## Verification Plan (Windows 10 PowerShell)

### Automated Tests

Ensure **Docker Desktop for Windows** is running (with WSL 2 backend enabled in Docker Desktop Settings $\rightarrow$ General), then run the following commands in **Windows PowerShell** from your project root folder:

1. **Create `.env` and `tmp_media` folder, then build and launch the Docker container:**
   ```powershell
   if (!(Test-Path .env)) { Copy-Item .env.example .env }
   New-Item -ItemType Directory -Force -Path .\tmp_media | Out-Null
   docker compose up -d --build
   ```

2. **Verify FFmpeg, `edge-tts`, Whisper, and font availability inside the n8n container:**
   ```powershell
   docker exec faceless_n8n ffmpeg -version
   docker exec faceless_n8n edge-tts --version
   docker exec faceless_n8n python3 -c "import faster_whisper; print('Whisper Ready')"
   docker exec faceless_n8n sh -c "fc-list | grep -i DejaVu"
   ```

3. **Run End-to-End Synthetic Dry-Run from Windows PowerShell (Zero API Keys Used):**
   ```powershell
   docker exec faceless_n8n sh -c "mkdir -p /tmp/faceless_pipeline/TEST_001 && cd /tmp/faceless_pipeline/TEST_001 && echo 'In nineteen seventy-two, deep beneath the Arctic ice, scientists uncovered a core sample that changed climate history forever.' > S01.txt && /home/node/scripts/generate_tts_and_probe.sh TEST_001 S01 /tmp/faceless_pipeline/TEST_001/S01.txt && ffmpeg -y -f lavfi -i testsrc=duration=10:size=1080x1920:rate=30 -c:v libx264 S01_clip.mp4 && /home/node/scripts/assemble_draft.sh TEST_001 1 && python3 /home/node/scripts/generate_srt.py TEST_001 && cp captions.srt approved_captions.srt && /home/node/scripts/burn_subtitles.sh TEST_001"
   ```

4. **Open the rendered test video directly in Windows 10 Media Player:**
   ```powershell
   Invoke-Item .\tmp_media\TEST_001\TEST_001_final.mp4
   ```

   *Expected Output:*
   * `generate_tts_and_probe.sh` outputs JSON with the exact duration of the synthesized neural voiceover (`S01_vo.mp3`).
   * `generate_srt.py` transcribes the spoken words into 4-word uppercase SRT blocks.
   * `burn_subtitles.sh` outputs `{"status":"OK","final_path":"/tmp/faceless_pipeline/TEST_001/TEST_001_final.mp4"}` and Windows opens the 9:16 video with synchronized neural narration and burned-in captions.

### Manual Verification (HITL End-to-End Pilot)

1. Open `http://localhost:5678` in your Windows browser and authenticate your **Google OAuth2** credential (Drive, Sheets, YouTube).
2. Add a 3-scene test project (`VID_001`, `Expected_Scenes = 3`) in the `Production_Tracker` Google Sheet and set `Videos!Status = SCRIPT_APPROVED`.
3. Confirm Workflow 1 runs `edge-tts` locally, populates `S01_vo.mp3`–`S03_vo.mp3` in Google Drive `/04_Audio`, records exact durations in `Scenes!Audio_Duration`, and advances `Videos!Status` to `VO_READY`.
4. Drop 3 test 9:16 MP4 clips (`S01_clip.mp4`–`S03_clip.mp4`) into `/03_Clips`, set `Videos!Status = ASSETS_READY`, and confirm Workflow 2 outputs `VID_001_draft.mp4` in `/05_Renders` (also accessible locally at `.\tmp_media\VID_001\VID_001_draft.mp4`) and populates `Videos!Subtitles_SRT`.
5. Edit one word in `Videos!Subtitles_SRT`, set `Videos!Status = RENDER_FINAL`, and verify `VID_001_final.mp4` reflects the edited subtitle and populates YouTube/Facebook metadata in the Sheet.
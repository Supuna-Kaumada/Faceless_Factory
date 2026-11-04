FROM node:20-bookworm-slim

USER root

# Install system dependencies, FFmpeg, fonts, dos2unix, curl, jq, and tini
RUN apt-get update && apt-get install -y --no-install-recommends \
    tini \
    ffmpeg \
    python3 \
    python3-pip \
    curl \
    jq \
    dos2unix \
    fontconfig \
    fonts-dejavu-core \
    && fc-cache -f -v \
    && rm -rf /var/lib/apt/lists/*

# Install edge-tts (free neural TTS) and faster-whisper (local word-level SRT generation)
RUN pip3 install --no-cache-dir --break-system-packages \
    edge-tts \
    faster-whisper

# Install n8n
RUN npm install -g n8n@1.82.2 --omit=dev

# Create working directories and set permissions for node user
RUN mkdir -p /tmp/faceless_pipeline /home/node/scripts /home/node/.n8n

# Copy scripts from Windows host, strip Windows CRLF line endings, and make executable
COPY ./scripts/ /home/node/scripts/
RUN dos2unix /home/node/scripts/*.sh /home/node/scripts/*.py \
    && chmod +x /home/node/scripts/*.sh /home/node/scripts/*.py \
    && chown -R node:node /tmp/faceless_pipeline /home/node/scripts /home/node/.n8n

USER node
WORKDIR /home/node

EXPOSE 5678

ENTRYPOINT ["tini", "--"]
CMD ["n8n"]

#!/bin/bash
# Download a ggml whisper model into Application Support.
# Usage: scripts/download-model.sh [base.en|large-v3-turbo|tiny.en] (default: base.en)
set -euo pipefail
MODEL="${1:-base.en}"
DIR="$HOME/Library/Application Support/Parla/models"
mkdir -p "$DIR"
FILE="$DIR/ggml-$MODEL.bin"
[ -f "$FILE" ] && { echo "already present: $FILE"; exit 0; }
curl -L --fail -o "$FILE" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin"
echo "downloaded: $FILE"

#!/usr/bin/env bash
set -euo pipefail

MODEL_ZIP_URL="https://github.com/GantMan/nsfw_model/releases/download/1.1.0/nsfw_mobilenet_v2_140_224.zip"
OUTPUT_DIR="${1:-assets/models}"

mkdir -p "$OUTPUT_DIR"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ZIP_PATH="$TMP_DIR/nsfw_model.zip"

printf 'Downloading NSFW model release...\n'
curl -L "$MODEL_ZIP_URL" -o "$ZIP_PATH"

printf 'Extracting TFLite model + labels...\n'
unzip -p "$ZIP_PATH" "mobilenet_v2_140_224/saved_model.tflite" > "$OUTPUT_DIR/nsfw_mobilenet_v2_140_224.tflite"
unzip -p "$ZIP_PATH" "mobilenet_v2_140_224/class_labels.txt" > "$OUTPUT_DIR/nsfw_labels.txt"

printf 'Done.\n'
ls -lh "$OUTPUT_DIR/nsfw_mobilenet_v2_140_224.tflite" "$OUTPUT_DIR/nsfw_labels.txt"

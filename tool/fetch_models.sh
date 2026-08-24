#!/usr/bin/env bash
# Downloads the VAD/STT/TTS models and the native sherpa-onnx library needed
# for pure-Dart runs. Flutter builds get the native library from the plugin and
# only need the models.
set -euo pipefail

SHERPA_VERSION="1.13.4"
MODELS_DIR="${SP_MODELS_DIR:-$(dirname "$0")/../models}"
NATIVE_DIR="${SP_NATIVE_LIB_DIR:-$(dirname "$0")/../native}"

mkdir -p "$MODELS_DIR" "$NATIVE_DIR"
MODELS_DIR="$(cd "$MODELS_DIR" && pwd)"
NATIVE_DIR="$(cd "$NATIVE_DIR" && pwd)"

ASR_BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models"
TTS_BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"
LIB_BASE="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VERSION}"

fetch_tar() {
  local url="$1" name="$2" dest="$3"
  if [ -d "$dest/$name" ]; then
    echo "· $name already present"
    return
  fi
  echo "↓ $name"
  curl -fL --progress-bar "$url" | tar -xj -C "$dest"
}

# --- VAD -------------------------------------------------------------------
if [ ! -f "$MODELS_DIR/silero_vad.onnx" ]; then
  echo "↓ silero_vad.onnx"
  curl -fL --progress-bar -o "$MODELS_DIR/silero_vad.onnx" \
    "$ASR_BASE/silero_vad.onnx"
else
  echo "· silero_vad.onnx already present"
fi

# --- STT: SenseVoice (zh/en/ja/ko/yue, non-streaming) ----------------------
fetch_tar \
  "$ASR_BASE/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2" \
  "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17" \
  "$MODELS_DIR"

# --- TTS: Kokoro (English, 11 voices, 24 kHz) ------------------------------
fetch_tar "$TTS_BASE/kokoro-en-v0_19.tar.bz2" "kokoro-en-v0_19" "$MODELS_DIR"

# --- TTS: Nepali (dedicated Piper voice) -----------------------------------
# Sanskrit needs nothing here: it reuses the English Kokoro bundle above,
# driven from our own Devanagari phonemizer rather than espeak-ng.
if [ "${SP_LANGS:-all}" = "all" ] || [[ "${SP_LANGS:-}" == *ne* ]]; then
  fetch_tar "$TTS_BASE/vits-piper-ne_NP-chitwan-medium.tar.bz2" \
    "vits-piper-ne_NP-chitwan-medium" "$MODELS_DIR"
fi

# --- STT fallback (optional) -----------------------------------------------
# Only worth fetching if you have not run tool/export_indicconformer.py.
# Whisper is measurably poor at Nepali; see README.
if [ "${SP_STT:-}" = "whisper" ]; then
  fetch_tar "$ASR_BASE/sherpa-onnx-whisper-small.tar.bz2" \
    "sherpa-onnx-whisper-small" "$MODELS_DIR"
fi

# --- Native library (pure-Dart only) ---------------------------------------
case "$(uname -s)" in
  Linux)  LIB_PKG="sherpa-onnx-v${SHERPA_VERSION}-linux-x64-shared" ;;
  Darwin)
    case "$(uname -m)" in
      arm64) LIB_PKG="sherpa-onnx-v${SHERPA_VERSION}-osx-arm64-shared" ;;
      *)     LIB_PKG="sherpa-onnx-v${SHERPA_VERSION}-osx-x86_64-shared" ;;
    esac ;;
  *) echo "! Unknown platform; fetch the native library manually from"
     echo "  $LIB_BASE" ; LIB_PKG="" ;;
esac

if [ -n "$LIB_PKG" ] && [ ! -f "$NATIVE_DIR/libsherpa-onnx-c-api.so" ] \
   && [ ! -f "$NATIVE_DIR/libsherpa-onnx-c-api.dylib" ]; then
  echo "↓ $LIB_PKG"
  tmp="$(mktemp -d)"
  curl -fL --progress-bar "$LIB_BASE/${LIB_PKG}.tar.bz2" | tar -xj -C "$tmp"
  find "$tmp" -name 'libsherpa-onnx-c-api.*' -o -name 'libonnxruntime.*' \
    | xargs -I{} cp {} "$NATIVE_DIR/"
  rm -rf "$tmp"
fi

echo
echo "Models:  $MODELS_DIR"
echo "Native:  $NATIVE_DIR"

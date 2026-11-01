#!/usr/bin/env bash
# Собирает хелпер распознавания речи capri-asr (tools/capri-asr) и CTranscribe.framework из transcribe.cpp
# на закреплённом коммите. Клон и сборка — в кэше Мака (~/Library/Caches/capri-asr), не в репозитории;
# повторный запуск без изменений — секунды. Печатает каталог с готовыми capri-asr и CTranscribe.framework.
# Только на Маке: scripts/mac.sh "bash scripts/build-asr-macos.sh".
set -euo pipefail
CAPRI_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$CAPRI_ROOT/scripts/swift-env.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

TRANSCRIBE_REPO=https://github.com/handy-computer/transcribe.cpp
TRANSCRIBE_COMMIT=5700f127e38dd53c4735ea23ef743b4b538eacd4   # 2026-10-27, проверен спайком
CACHE=${CAPRI_ASR_CACHE:-$HOME/Library/Caches/capri-asr}
SRC="$CACHE/transcribe.cpp"
XCF="$SRC/bindings/swift/build-apple/TranscribeCpp.xcframework"
mkdir -p "$CACHE"

command -v cmake >/dev/null || { echo "нужен cmake (brew install cmake)" >&2; exit 1; }

if [[ ! -d "$SRC/.git" ]]; then
  git clone --quiet --filter=blob:none "$TRANSCRIBE_REPO" "$SRC" >&2
fi
if [[ "$(git -C "$SRC" rev-parse HEAD)" != "$TRANSCRIBE_COMMIT" ]]; then
  git -C "$SRC" fetch --quiet origin "$TRANSCRIBE_COMMIT" >&2 || true
  git -C "$SRC" checkout --quiet --force "$TRANSCRIBE_COMMIT" >&2
  rm -rf "$XCF" "$CACHE/xcf.stamp"
fi

# xcframework (только macOS: arm64 с Metal + x86_64 на CPU) — долго, один раз на коммит.
if [[ ! -d "$XCF" || "$(cat "$CACHE/xcf.stamp" 2>/dev/null)" != "$TRANSCRIBE_COMMIT" ]]; then
  echo "transcribe.cpp $TRANSCRIBE_COMMIT: собираю xcframework (несколько минут)…" >&2
  TRANSCRIBE_XCFRAMEWORK_SLICES=macos bash "$SRC/scripts/ci/build_xcframework.sh" > "$CACHE/xcf.log" 2>&1 \
    || { tail -30 "$CACHE/xcf.log" >&2; exit 1; }
  echo "$TRANSCRIBE_COMMIT" > "$CACHE/xcf.stamp"
fi

export CAPRI_TRANSCRIBE_SWIFT="$SRC/bindings/swift"
cd "$CAPRI_ROOT/tools/capri-asr"
swift build -c release --scratch-path "$CACHE/build" >&2
BIN="$(swift build -c release --scratch-path "$CACHE/build" --show-bin-path)"
test -x "$BIN/capri-asr" && test -d "$BIN/CTranscribe.framework"
# Лицензии для бандла: transcribe.cpp (MIT) и то, что он вшивает (ggml и др.).
{
  echo "# Third-party licenses (capri-asr)"
  echo
  echo "Capri's speech helper links transcribe.cpp ($TRANSCRIBE_REPO, commit $TRANSCRIBE_COMMIT)."
  echo "The speech model (NVIDIA Nemotron ASR, OpenMDW-1.1) is not bundled; it is read from the Hugging Face cache."
  echo
  echo "## transcribe.cpp"
  echo
  cat "$SRC/LICENSE"
  echo
  cat "$SRC/THIRD-PARTY-LICENSES.md"
} > "$BIN/THIRD-PARTY-LICENSES.md"
echo "$BIN"

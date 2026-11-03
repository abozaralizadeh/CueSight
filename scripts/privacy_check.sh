#!/usr/bin/env bash
# Checks the app's code for anything that could save or send camera images.
# The app should have no networking at all, and write only text and JSON files.
# Run it before every release. It exits with 1 if it finds something to look at.
set -u
cd "$(dirname "$0")/.."

# Code that ends up in the app: the App folder and the package libraries, not the bench tool.
paths=(App/Sources CueSightKit/Sources/ShotEngine CueSightKit/Sources/TableVision CueSightKit/Sources/SessionCore CueSightKit/Sources/SceneSim)

network='URLSession|URLRequest|NWConnection|NWPathMonitor|import Network|CFNetwork|CFStream|WKWebView|SFSafariViewController'
images='UIImageWriteToSavedPhotosAlbum|PHPhotoLibrary|PHAsset|pngData|jpegData|heicData|CGImageDestination|AVAssetWriter|ARVideoRecorder'
recording='SceneRecording'

found=0
check() {
  local label=$1 pattern=$2
  local hits
  # SceneRecording.swift is allowed to write frames: it's only for the bench, see the check below.
  hits=$(grep -rnE "$pattern" "${paths[@]}" 2>/dev/null | grep -v 'SessionCore/SceneRecording.swift' || true)
  if [ -n "$hits" ]; then
    echo "Found $label:"
    echo "$hits"
    found=1
  fi
}

check "networking code" "$network"
check "code that saves images" "$images"
# SceneRecording saves frames to disk. It's for the bench and tests only, never the app.
hits=$(grep -rn "$recording" App/Sources || true)
if [ -n "$hits" ]; then
  echo "The app uses SceneRecording, which saves camera frames:"
  echo "$hits"
  found=1
fi

if [ $found -eq 0 ]; then
  echo "OK: no networking, no image saving and no frame recording in the app's code."
fi
exit $found

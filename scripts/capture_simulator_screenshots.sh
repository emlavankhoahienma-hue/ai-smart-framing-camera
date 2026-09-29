#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "Error: App path not provided or does not exist: '$APP_PATH'"
  exit 1
fi

BUNDLE_ID="com.aismartframing.camera"
SCREENSHOT_DIR="screenshots"
mkdir -p "$SCREENSHOT_DIR"

# Preserve diagnostics and prevent an unresponsive simulator service from
# holding the CI job indefinitely.
run_bounded() {
  python3 - "$@" <<'PY'
import os
import signal
import subprocess
import sys

timeout = float(sys.argv[1])
command = sys.argv[2:]
print("Running:", " ".join(command), flush=True)
process = subprocess.Popen(command, start_new_session=True)
try:
    status = process.wait(timeout=timeout)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    print(f"Timed out after {timeout}s: {command}", flush=True)
    status = 124
raise SystemExit(status)
PY
}

echo "=== iOS Simulator Screenshot Tool ==="
echo "App bundle: $APP_PATH"
echo "Bundle ID: $BUNDLE_ID"
echo "Output directory: $SCREENSHOT_DIR"
echo ""

echo "--- Available iOS Simulators ---"
xcrun simctl list devices available || true
echo ""

find_device_udid() {
  local pattern="$1"
  local match
  match=$(xcrun simctl list devices available | (grep -E "$pattern" || true) | head -n 1 | (grep -oE '\([0-9a-fA-F-]{36}\)' || true) | tr -d '()')
  echo "$match"
}

capture_device() {
  local label="$1"
  local pattern="$2"
  local filename="$3"

  echo "----------------------------------------"
  echo "Processing: $label"
  local udid
  udid=$(find_device_udid "$pattern" || true)

  if [ -z "$udid" ]; then
    echo "Notice: Could not locate available device matching '$pattern'. Skipping $label."
    return 0
  fi

  echo "Found UDID: $udid"

  echo "Shutting down existing booted simulators..."
  run_bounded 30 xcrun simctl shutdown all || true

  echo "Booting $label ($udid)..."
  run_bounded 45 xcrun simctl boot "$udid"

  echo "Waiting for simulator services..."
  run_bounded 120 xcrun simctl bootstatus "$udid" -b

  echo "Installing application bundle..."
  run_bounded 180 xcrun simctl install "$udid" "$APP_PATH"

  echo "Granting permissions for camera, photos and microphone..."
  run_bounded 15 xcrun simctl privacy "$udid" grant camera "$BUNDLE_ID" || true
  run_bounded 15 xcrun simctl privacy "$udid" grant photos "$BUNDLE_ID" || true
  run_bounded 15 xcrun simctl privacy "$udid" grant microphone "$BUNDLE_ID" || true

  echo "Launching application ($BUNDLE_ID)..."
  run_bounded 40 xcrun simctl launch "$udid" "$BUNDLE_ID"

  echo "Waiting 7 seconds for SwiftUI render and animations..."
  sleep 7

  local target_image="${SCREENSHOT_DIR}/${filename}.png"
  echo "Capturing screenshot to: $target_image"
  run_bounded 30 xcrun simctl io "$udid" screenshot "$target_image"

  if [ -f "$target_image" ]; then
    echo "Screenshot saved successfully: $(ls -lh "$target_image" | awk '{print $5, $9}')"
    if command -v sips >/dev/null 2>&1; then
      sips -g pixelWidth -g pixelHeight "$target_image" || true
    fi
  else
    echo "Warning: Screenshot file not generated."
  fi

  echo "Shutting down simulator ($udid)..."
  run_bounded 30 xcrun simctl shutdown "$udid" || true
  echo "Completed: $label"
}

# 1. iPhone SE (Smallest form factor - 375x667, 16:9, physical Home button)
capture_device "iPhone SE (3rd generation)" "iPhone SE \(3rd generation\)|iPhone SE" "01_iPhone_SE_3rd_Gen"

# 2. iPhone 16 / 15 Standard (6.1 inch, Dynamic Island)
capture_device "iPhone Standard (6.1 inch)" "iPhone 16$|iPhone 16 \(|iPhone 15$|iPhone 15 \(" "02_iPhone_Standard_6_1"

# 3. iPhone Pro Max (Largest form factor - 6.7 to 6.9 inch)
capture_device "iPhone Pro Max" "iPhone 16 Pro Max|iPhone 15 Pro Max" "03_iPhone_Pro_Max"

echo "----------------------------------------"
echo "Screenshot capture session finished."
ls -lh "$SCREENSHOT_DIR"

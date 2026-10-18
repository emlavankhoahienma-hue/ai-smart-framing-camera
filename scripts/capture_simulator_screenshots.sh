#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
SNAPSHOT_MODE="${2:-camera}"
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "Error: App path not provided or does not exist: '$APP_PATH'"
  exit 1
fi

BUNDLE_ID="com.aismartframing.camera"
SCREENSHOT_DIR="screenshots"
mkdir -p "$SCREENSHOT_DIR"
DIAGNOSTIC_DIR="simulator-diagnostics"
mkdir -p "$DIAGNOSTIC_DIR"

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

collect_diagnostics() {
  local udid="$1"
  local label="$2"
  run_bounded 20 xcrun simctl list devices --json > "${DIAGNOSTIC_DIR}/${label}-devices.json" 2>&1 || true
  run_bounded 20 xcrun simctl spawn "$udid" log show --style compact --last 2m \
    --predicate 'process == "AISmartFramingCamera" OR subsystem == "com.apple.FrontBoard"' \
    > "${DIAGNOSTIC_DIR}/${label}-launch.log" 2>&1 || true
  local reports="${HOME}/Library/Developer/CoreSimulator/Devices/${udid}/data/Library/Logs/CrashReporter"
  if [ -d "$reports" ]; then
    find "$reports" -maxdepth 1 -type f -name '*AISmartFramingCamera*' \
      -exec cp '{}' "$DIAGNOSTIC_DIR/" \;
  fi
}

record_motion() {
  python3 - "$1" "$2" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys

udid, output = sys.argv[1:]
command = ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", output]
print("Recording:", " ".join(command), flush=True)
process = subprocess.Popen(command, start_new_session=True)
try:
    process.wait(timeout=12)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGINT)
    try:
        status = process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        print("Timed out while finishing simulator recording", flush=True)
        raise SystemExit(124)
else:
    print("Simulator recording ended before the capture interval", flush=True)
    raise SystemExit(process.returncode or 1)
if status != 0:
    raise SystemExit(status)
if not Path(output).is_file() or Path(output).stat().st_size == 0:
    raise SystemExit("Simulator recording did not produce a nonempty movie")
PY
}

capture_stage() {
  local udid="$1"
  local filename="$2"
  local mode="$3"
  local stage="$4"
  case "${mode}:${stage}" in
    window:photo|window:square|window:video|zoom:guide|zoom:aligned|zoom:preview|zoom:ramp|zoom:verify|zoom:zoomout|zoom:lost|zoom:motion) ;;
    *) echo "Invalid snapshot stage: ${mode}:${stage}"; return 2 ;;
  esac
  local url="alignai-snapshot://${mode}?stage=${stage}"
  local attempt status
  for attempt in 1 2; do
    status=0
    # Opening a URL cold-starts the installed host when necessary, or updates
    # its existing SwiftUI state. No per-stage process termination is needed.
    if run_bounded 40 xcrun simctl openurl "$udid" "$url"; then
      if [ "$stage" = "motion" ]; then
        record_motion "$udid" "${SCREENSHOT_DIR}/${filename}.mp4" || status=$?
      else
        sleep 2
        run_bounded 30 xcrun simctl io "$udid" screenshot "${SCREENSHOT_DIR}/${filename}.png" || status=$?
        if [ "$status" -eq 0 ] && [ ! -s "${SCREENSHOT_DIR}/${filename}.png" ]; then
          echo "Simulator screenshot did not produce a nonempty image"
          status=1
        fi
      fi
    else
      status=$?
    fi
    if [ "$status" -eq 0 ]; then return 0; fi
    collect_diagnostics "$udid" "${filename}-attempt-${attempt}"
    # Only a bounded transport timeout admits one cold-service recovery. An
    # actual launch/capture error still fails; repeated timeouts also fail.
    if [ "$status" -ne 124 ] || [ "$attempt" -eq 2 ]; then return "$status"; fi
    echo "Recovering simulator transport once for ${filename}"
    run_bounded 30 xcrun simctl shutdown "$udid" || return $?
    run_bounded 45 xcrun simctl boot "$udid" || return $?
    run_bounded 120 xcrun simctl bootstatus "$udid" -b || return $?
    run_bounded 180 xcrun simctl install "$udid" "$APP_PATH" || return $?
  done
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

  if [ "$SNAPSHOT_MODE" = "window" ]; then
    for stage in photo square video; do
      capture_stage "$udid" "${filename}_${stage}" window "$stage"
    done
    run_bounded 30 xcrun simctl shutdown "$udid"
    return 0
  elif [ "$SNAPSHOT_MODE" = "zoom" ]; then
    for stage in guide aligned preview ramp verify zoomout lost; do
      capture_stage "$udid" "${filename}_${stage}" zoom "$stage"
    done
    capture_stage "$udid" "${filename}_motion" zoom motion
    run_bounded 30 xcrun simctl shutdown "$udid"
    return 0
  fi

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

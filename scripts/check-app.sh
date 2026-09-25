#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

if [ "$(uname -s)" != "Darwin" ]; then
  echo "check-app.sh requires macOS (AppKit, IOKit, and UserNotifications)." >&2
  exit 2
fi

check_dir=$(mktemp -d "${TMPDIR:-/tmp}/battery-monitor-runtime.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM

swiftc -parse-as-library \
  Sources/BatteryMonitor/Models.swift \
  Sources/BatteryMonitor/HistoryStore.swift \
  Sources/BatteryMonitor/AnalyticsEngine.swift \
  Sources/BatteryMonitor/BatteryReader.swift \
  Sources/BatteryMonitor/ProcessReader.swift \
  Sources/BatteryMonitor/AppModel.swift \
  Tests/RuntimeTests.swift \
  -o "$check_dir/runtime-check"

"$check_dir/runtime-check"

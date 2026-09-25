#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d "${TMPDIR:-/tmp}/battery-monitor-analytics.XXXXXX")
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
swiftc -parse-as-library Sources/BatteryMonitor/Models.swift Sources/BatteryMonitor/HistoryStore.swift Sources/BatteryMonitor/AnalyticsEngine.swift Tests/AnalyticsHarness.swift -o "$check_dir/analytics-check"
"$check_dir/analytics-check"

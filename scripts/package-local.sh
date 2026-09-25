#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir="$repo_dir/build/package"

if [ -L "$repo_dir/build" ] || [ -L "$output_dir" ]; then
  echo "Refusing to package through a symlinked build directory: $repo_dir/build" >&2
  exit 1
fi

cd "$repo_dir"
command -v xcodegen >/dev/null 2>&1 || {
  echo "xcodegen is required (install it with: brew install xcodegen)" >&2
  exit 1
}

xcodegen generate --spec project.yml
xcodebuild \
  -quiet \
  -project BatteryMonitor.xcodeproj \
  -scheme BatteryMonitor \
  -configuration Release \
  -derivedDataPath "$repo_dir/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

source_app="$repo_dir/build/DerivedData/Build/Products/Release/Battery Monitor.app"
test -d "$source_app" || {
  echo "Build succeeded but the app bundle was not found at: $source_app" >&2
  exit 1
}

mkdir -p "$output_dir"
target_app="$output_dir/Battery Monitor.app"
rm -rf -- "$target_app"
ditto "$source_app" "$target_app"
echo "Unsigned local app: $target_app"

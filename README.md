# Battery Monitor

A native macOS menu bar and dashboard app for battery telemetry, local history, and power-use explanations. Requires macOS 14 or later. The app stores readings on this Mac and sends no telemetry to a server.

## Build and run

Requirements: macOS 14 or later, Xcode command line tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

Build and package an unsigned local app:

```sh
./scripts/package-local.sh
```

The script regenerates `BatteryMonitor.xcodeproj`, builds the Release configuration with code signing disabled, and copies the app to `build/package/Battery Monitor.app`. The output has no Developer ID signature or notarization and is not ready for distribution; Xcode may still apply an ad hoc linker signature to the executable.

To build and run the Debug app directly:

```sh
xcodegen generate
xcodebuild -project BatteryMonitor.xcodeproj -scheme BatteryMonitor -configuration Debug -derivedDataPath DerivedData build
open "DerivedData/Build/Products/Debug/Battery Monitor.app"
```

The generated Xcode project is ignored by Git; `project.yml` is its source. Notification permission is requested when an enabled alert first fires.

### Optional Developer ID signing and notarization

Distribution requires an Apple Developer Program membership, a valid `Developer ID Application` certificate, and notarization. Configure these in your own Xcode/keychain environment; this repository and the local package script do not read or store signing credentials. For a signed archive, use Xcode's Organizer or run `xcodebuild archive` with your own `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY="Developer ID Application"` overrides and `CODE_SIGNING_ALLOWED=YES`. Validate the resulting app with `codesign --verify --deep --strict --verbose=2`, create a ZIP with `ditto -c -k --keepParent`, submit it using `xcrun notarytool submit` and a keychain profile you configured yourself, wait for acceptance, then staple and validate with `xcrun stapler staple` and `xcrun stapler validate`. See Apple's guides for [code signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) and [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution). The local output does not establish a signed or notarized release.

## How readings are measured

- Battery level, charging state, estimated time, cycle count, capacities, voltage, temperature, and adapter information come from macOS power sources and IOKit when the hardware exposes them. Missing values are shown as unavailable.
- Battery power is estimated from the battery controller's current and voltage. Adapter rating is not the same as watts entering the battery.
- App activity uses process CPU usage as a clue; macOS does not provide public, reliable per-app watt readings. App shares are estimates of observed CPU activity, not a division of the whole Mac's drain.
- macOS does not expose dependable screen-on or brightness history to this app. USB-C port identity is unavailable when the battery data source does not report it.
- Forecasts, daily scores, drain explanations, and health trends depend on locally collected history. They become more useful after the app has run for some time, and cannot reconstruct usage before installation.
- A/B power experiments compare average measured battery drain while each phase is active. Run them unplugged with similar workloads and enough time in each phase to reduce noise.

## Local data and privacy

Battery history stays on this Mac. The app does not send telemetry to a server. Readings and process activity samples are stored in `~/Library/Application Support/BatteryMonitor/history.json`; app preferences are stored in macOS `UserDefaults`. History is compacted to retain at most 90 days, with older samples downsampled within that window. In **Settings → Data & privacy**, turn off **Collect process activity** to stop recording active app names, or use **Clear History** to erase retained readings, events, process samples, and charging sessions. Removing the app alone may leave these local files behind, so clear history in the app before uninstalling if you want to remove it.

For local verification, run `./scripts/check-analytics.sh` and `./scripts/check-app.sh`.

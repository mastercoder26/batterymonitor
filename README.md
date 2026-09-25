# Battery Monitor

A menu bar app for your Mac's battery. It shows charge, power draw, history, and a plain explanation of what was using the machine. It runs on macOS 14 or later and keeps everything on this Mac.

[Download the latest build](https://github.com/mastercoder26/batterymonitor/releases/download/v1.0.0/BatteryMonitor-macOS.zip)

Unzip it and open `Battery Monitor.app`. The build is unsigned. If macOS refuses to open it, right-click the app, choose Open, then Open again.

## Build it yourself

You need macOS 14, Xcode command line tools, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./scripts/package-local.sh
```

That writes an unsigned app to `build/package/Battery Monitor.app`.

For a Debug build:

```sh
xcodegen generate
xcodebuild -project BatteryMonitor.xcodeproj -scheme BatteryMonitor -configuration Debug -derivedDataPath DerivedData build
open "DerivedData/Build/Products/Debug/Battery Monitor.app"
```

`project.yml` is the project file. The generated Xcode project is left out of Git. The app asks for notification permission the first time an alert you turned on actually fires.

## What the numbers mean

macOS reports charge, charging state, time remaining, cycles, capacity, voltage, temperature, and adapter info when the hardware has them. If a value is missing, the app says so.

Watts are estimated from the battery's current and voltage. The adapter's rated watts are the charger's size, which is separate from how much power is going into the battery.

App names come from CPU use. macOS does not give this app a real watt number per app, so those shares are a hint about which apps were busy.

Screen-on time and brightness are not available here. USB-C port names only show up if the battery data includes them.

Forecasts, daily scores, drain notes, and health trends come from history the app recorded after you installed it. They get better the longer it runs.

The A/B experiments compare average battery drain during two stretches. Unplug, keep the workload similar, and give each side enough time.

## What stays on this Mac

Readings and app activity samples go in `~/Library/Application Support/BatteryMonitor/history.json`. Settings stay in User Defaults. Nothing is sent to a server.

History is kept for about 90 days. Older samples inside that window are thinned out.

In Settings, under Data & privacy, turn off Collect process activity if you do not want app names saved. Clear History deletes the saved readings, events, process samples, and charging sessions. Deleting the app can leave that file behind, so clear history first if you want it gone.

To check the logic locally:

```sh
./scripts/check-analytics.sh
./scripts/check-app.sh
```

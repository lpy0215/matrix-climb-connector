# Matrix Climb Connector

## Architecture

- `MatrixClimbConnector/iOS` contains the iPhone SwiftUI app. It discovers and connects to a user-selected FTMS machine over CoreBluetooth, parses Step Climber Data (`0x2ACF`), keeps the local workout record, and controls the mirrored workout session.
- `MatrixClimbConnector/watchOS` contains the Apple Watch SwiftUI app. It owns the primary `HKWorkoutSession` and `HKLiveWorkoutBuilder`, collects Apple Watch heart rate and Active Energy, adds final Matrix floors/elevation, and saves the workout.
- `MatrixClimbConnector/Shared` contains data models, the FTMS parser, message coding, and shared formatting used by the app targets.
- `MatrixClimbConnectorTests` contains iOS-hosted unit tests for the FTMS parser and workout message codec.
- The shared schemes are `MatrixClimbConnector` and `MatrixClimbConnector Watch App`.

## Build and test

Use Xcode 26 or later. CI selects the `macos-26` runner's default Xcode and rejects an older toolchain.

```sh
xcodebuild -project MatrixClimbConnector.xcodeproj \
  -scheme MatrixClimbConnector \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcodebuild -project MatrixClimbConnector.xcodeproj \
  -scheme 'MatrixClimbConnector Watch App' \
  -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcodebuild -project MatrixClimbConnector.xcodeproj \
  -scheme MatrixClimbConnector \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
```

Bluetooth discovery, workout mirroring, HealthKit authorization, and the final saved workout still require a physical iPhone and paired Apple Watch.

## Product invariants

- Never hard-code a complete BLE peripheral name. Advertising FTMS is preferred; partial Matrix/ClimbMill name hints are candidates only, and compatibility is decided after service and characteristic discovery.
- RSSI may sort candidates but must never select a machine automatically.
- Matrix energy is diagnostic/local-record data and must never replace Apple Watch Active Energy.
- Only the primary Watch target may call `finishWorkout()` and save the `HKWorkout`; the iPhone target must not create or finish a workout.
- Store Matrix SPM and step count only in the local workout record. Do not map them to unrelated HealthKit quantity types.
- Use Matrix Floors directly for `flightsClimbed` and Matrix Positive Elevation Gain directly for `HKMetadataKeyElevationAscended`; do not reconstruct either value from another metric.
- Preserve malformed-packet rejection and partial-notification merging in the FTMS parser. Do not disable tests or remove HealthKit/Watch functionality to make CI pass.
- Never add signing certificates, provisioning profiles, Apple credentials, API keys, or secrets to the repository.

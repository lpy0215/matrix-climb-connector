# Matrix ClimbMill → Apple Watch / HealthKit MVP

An iPhone + Apple Watch SwiftUI app for FTMS Step Climber Data (`0x2ACF`). The iPhone connects to a user-selected ClimbMill over CoreBluetooth. Apple Watch owns the primary indoor stair-climbing workout and HealthKit save operation.

## Requirements

- Xcode 26 or newer
- iOS 17 or newer
- watchOS 10 or newer
- Physical iPhone and paired Apple Watch for workout mirroring
- FTMS machine exposing Fitness Machine Service `0x1826` and a notifiable Step Climber Data characteristic `0x2ACF`

Bluetooth and workout mirroring cannot be fully exercised in the simulator.

## First build

1. Open `MatrixClimbConnector.xcodeproj`.
2. Select the project, then assign the same Apple Developer Team to:
   - `MatrixClimbConnector`
   - `MatrixClimbConnector Watch App`
   - `MatrixClimbConnectorTests`
3. Replace the placeholder identifiers in both Debug and Release build settings:
   - iPhone `PRODUCT_BUNDLE_IDENTIFIER`: `com.example.MatrixClimbConnector`
   - Watch `PRODUCT_BUNDLE_IDENTIFIER`: `com.example.MatrixClimbConnector.watchkitapp`
   - Watch `WK_COMPANION_APP_BUNDLE_IDENTIFIER`: exactly the iPhone bundle identifier
4. Confirm HealthKit capability is present on both app targets, Background Modes → Uses Bluetooth LE accessories is present on iPhone, and Workout processing is present on Watch.
5. Enable Developer Mode on the iPhone and Apple Watch.
6. Select the `MatrixClimbConnector` scheme and the physical iPhone paired with the target Watch, then Run.
7. Run the `MatrixClimbConnector Watch App` scheme once on the physical Watch if Xcode does not install the companion automatically.

## Real-device flow

1. Open the iPhone app beside the ClimbMill.
2. Select the intended machine from the RSSI-sorted list. RSSI is never used for automatic selection.
3. Wait for `Connected`. This means post-connection discovery confirmed:
   - Fitness Machine Service `0x1826`
   - Step Climber Data `0x2ACF`
   - Notify property and successful notification enablement
4. Confirm the displayed BLE name, Floors, SPM, and elapsed time match the console.
5. Tap **Start stair-climbing workout** and approve Health permissions on Apple Watch.
6. Confirm Apple Watch heart rate and Active Energy appear on both devices.
7. Tap **End and save workout** once.
8. In Fitness/Health, confirm exactly one indoor Stair Climbing workout exists.

## Data ownership

| Value | Source | Destination |
| --- | --- | --- |
| Workout duration/type | Watch workout session | One HealthKit `.stairClimbing` workout |
| Heart rate | Apple Watch / HealthKit live data source | HealthKit workout + live UI |
| Active energy | Apple Watch / HealthKit live data source | HealthKit workout + live UI |
| Flights climbed | Matrix FTMS Floors | HealthKit `flightsClimbed` sample |
| Elevation ascended | Matrix FTMS Positive Elevation Gain | `HKMetadataKeyElevationAscended` on workout |
| Steps, current/average SPM | Matrix FTMS | Local app workout record only |
| Matrix kcal, machine HR, MET | Matrix FTMS | Local app workout record/debug UI only |

The iPhone never creates an `HKWorkout`. Only the primary Watch `HKLiveWorkoutBuilder` calls `finishWorkout()`, preventing duplicate workout records. Matrix energy never replaces Apple Active Energy. Matrix Floors and Positive Elevation Gain are used directly; neither is reconstructed from another metric.

## Workout synchronization

- Apple Watch owns the primary `HKWorkoutSession`; iPhone receives the mirrored session through `workoutSessionMirroringStartHandler`.
- The primary session reaches `.prepared` before mirroring begins, then starts the indoor stair-climbing activity and live builder collection.
- FTMS metrics and Watch snapshots use `sendToRemoteWorkoutSession`; there is no custom socket or WatchConnectivity workout protocol.
- Ending on iPhone calls `stopActivity` on the mirrored session. HealthKit propagates the state to Watch, which adds final Matrix Floors/Elevation, ends collection, calls `finishWorkout()` once, and finally ends the session.

## Device discovery behavior

- Scanning is intentionally unfiltered so machines that omit `0x1826` from advertising can still appear as name-based candidates.
- Advertising `0x1826` is the preferred candidate signal.
- `CTM…`, `Matrix`, `ClimbMill`, and `Step Climber` are auxiliary name hints only.
- No complete peripheral name is hard-coded.
- Compatibility is decided only after service/characteristic discovery.
- The last successful CoreBluetooth peripheral identifier is recorded only to mark the recent machine; manual selection and capability verification remain mandatory.

## FTMS parser

`FTMSStepClimberParser` implements the Bluetooth SIG Step Climber Data layout:

- 16-bit little-endian Flags first
- bit 0 inverted (`0` includes Floors and Step Count)
- bits 1–8 dynamically gate remaining fields
- compound Expended Energy consumes 5 bytes
- Positive Elevation Gain resolution: `0.1 m`
- Metabolic Equivalent resolution: `0.1 MET`
- reserved flags, truncation, and trailing bytes are rejected
- partial `More Data` notifications merge over the last known values for live display

Unit tests cover the observed `0x01FE` shape, mandatory-only data, a partial record, malformed compound energy, reserved flags, trailing data, and message codec round trips.

## Local workout record

Every accepted FTMS notification and every Watch snapshot is retained in:

`Application Support/MatrixClimbConnector/workout-records.json`

The record includes peripheral identifier/name, start/end timestamps, full parsed Matrix metric samples, Apple Watch heart rate snapshots, and Apple Active Energy snapshots. It is local app data and does not add SPM or Matrix step count to unrelated HealthKit quantity types.

## Relevant source files

- `MatrixClimbConnector/Shared/FTMSStepClimberParser.swift`
- `MatrixClimbConnector/iOS/Bluetooth/ClimbMillBluetoothManager.swift`
- `MatrixClimbConnector/iOS/Workout/PhoneWorkoutMirrorManager.swift`
- `MatrixClimbConnector/watchOS/Workout/WatchWorkoutManager.swift`
- `MatrixClimbConnectorTests/FTMSStepClimberParserTests.swift`

## Specifications and platform references

- [Bluetooth SIG Fitness Machine Service 1.0.1](https://www.bluetooth.com/specifications/specs/fitness-machine-service-1-0-1/)
- [Apple: Building a multidevice workout app](https://developer.apple.com/documentation/healthkit/building-a-multidevice-workout-app)
- [Apple: Running workout sessions](https://developer.apple.com/documentation/healthkit/running-workout-sessions)
- [Apple: HKMetadataKeyElevationAscended](https://developer.apple.com/documentation/healthkit/hkmetadatakeyelevationascended)

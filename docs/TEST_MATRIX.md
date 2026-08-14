# Test Matrix

This project uses free GitHub-hosted standard runners to validate everything
that does not require physical Apple or FTMS hardware. A green CI run does not
prove Bluetooth discovery, workout mirroring, HealthKit authorization, or the
final saved workout on real devices.

## Automated gates

| Gate | Environment | What it verifies | What it cannot verify |
| --- | --- | --- | --- |
| Core tests | `ubuntu-latest`, `swift test --configuration debug` | FTMS parsing, malformed-packet rejection, record assembly, workout message coding, and local-record persistence/export formats | CoreBluetooth, HealthKit, SwiftUI, or Apple target integration |
| iPhone build | `macos-26`, unsigned iOS Simulator build | iOS target compiles with Xcode 26 or later | Bluetooth radio behavior, signing, or installation |
| Watch build | `macos-26`, unsigned watchOS Simulator build | Watch target and HealthKit integration compile | Watch sensors, workout mirroring, signing, or installation |
| iOS-hosted unit tests | `macos-26`, iPhone Simulator | Core tests plus local-record checkpoint scheduling, recovery, retry, and corrupt-file handling | Real FTMS notifications or HealthKit persistence |

The Linux core job runs first. The Xcode job starts only after it passes, so a
fast portable failure does not consume a macOS runner. Xcode diagnostics are
uploaded only when that job fails and expire after 14 days.

## Free development workflow

1. Make changes on a feature branch and open a pull request.
2. Let `Core tests (Linux)` run the Foundation-only package in `Package.swift`.
3. Let `Xcode build and test` build both simulator apps and run the iOS-hosted tests.
4. If Xcode fails, inspect the failure-only `xcode-diagnostics-*` artifact.
5. Merge only after both jobs pass.

Windows does not need Xcode or a local Swift installation for this workflow;
GitHub Actions is the reproducible test environment. If the official Swift
toolchain is already installed locally, the portable subset can also be run
from the repository root:

```sh
swift test --configuration debug
```

The Apple simulator commands require Xcode 26 or later and are documented in
the repository `AGENTS.md` file.

## Physical-device checkpoint

These checks remain manual until an iPhone, paired Apple Watch, and compatible
Matrix ClimbMill are available:

| Check | Required evidence |
| --- | --- |
| User selects the intended machine; RSSI never selects automatically | Candidate list and selected peripheral name/identifier |
| Service discovery confirms `0x1826` and notifiable `0x2ACF` | Connection log and first accepted notification |
| Displayed Floors, SPM, elevation, energy, and elapsed time match the console | Side-by-side values during a workout |
| Watch heart rate and Active Energy reach both devices | Live iPhone and Watch readings |
| Ending from iPhone stops the mirrored Watch session | State transition log on both devices |
| Exactly one indoor stair-climbing workout is saved | Fitness/Health workout detail |
| Matrix Floors and Positive Elevation Gain are stored directly | Saved flights climbed and elevation metadata |
| Matrix steps/SPM stay local and Matrix energy does not replace Active Energy | Local record and HealthKit inspection |

For each physical run, record the date, commit SHA, iPhone/iOS version,
Watch/watchOS version, machine model/firmware, and pass/fail notes.

## Zero-cost boundaries

- Keep the repository public and use only standard GitHub-hosted runners.
- Simulator builds disable code signing and never require Apple credentials.
- Do not commit certificates, provisioning profiles, API keys, or account secrets.
- Do not add paid device-cloud services for Bluetooth or HealthKit claims; they
  cannot replace the final real-machine validation anyway.

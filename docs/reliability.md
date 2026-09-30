# AppStage Reliability Validation

AppStage uses two validation layers: GitHub-hosted Core CI for package
correctness and local GUI verification for end-to-end reliability.

## Core CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `main`. It runs:

1. `swift build`
2. `swift test`
3. `swift build -c release`

Core CI does not launch GUI apps or exercise Accessibility, ScreenCaptureKit,
the Fixture Host, or `appstage verify`.

## Local GUI verification

Build AppStage and the deterministic Fixture Host:

```sh
swift build
arch="$(uname -m)"
xcodebuild \
  -project Fixtures/AppStageTestHost/AppStageTestHost.xcodeproj \
  -scheme AppStageTestHost \
  -configuration Debug \
  -destination "platform=macOS,arch=$arch" \
  -derivedDataPath Fixtures/AppStageTestHost/build \
  ARCHS="$arch" \
  build
```

The Fixture Host exposes one deterministic Scenario, `reliability-smoke`.
Before verification, run the local environment preflight and then `verify`:

```sh
FIXTURE_APP="$PWD/Fixtures/AppStageTestHost/build/Build/Products/Debug/AppStageTestHost.app"
OUTPUT_ROOT="$HOME/Desktop/AppStage-Verify"

.build/debug/appstage doctor --app "$FIXTURE_APP" --json \
  --output "$OUTPUT_ROOT/environment.json"

.build/debug/appstage verify \
  --app "$FIXTURE_APP" \
  --iterations 1 \
  --retain-movies failures \
  --output "$OUTPUT_ROOT"
```

`doctor` is a local reliability preflight. It reports macOS version, GUI
session, Accessibility, Screen Recording, display, Host app, residual Host
processes, disk space, Xcode, and Swift. A failing preflight returns non-zero;
the JSON report is still written when environment checks fail.

`verify` discovers the Host's Scenarios and runs every discovered Scenario for
the requested number of rounds. Each attempt exercises the Control connection,
Scenario lifecycle, recording, MOV validation, and process cleanup. It writes a
`summary.json` and `summary.txt` in the run directory under `OUTPUT_ROOT`.
Inspect the summary for pass/fail counts, invalid MOVs, orphan processes, and
cleanup failures. Per-attempt `result.json` and `trace.json` are stored under
each Scenario's `attempt-NNN` directory. Failed attempts also retain
`diagnostics.json` and, with `--retain-movies failures`, their `recording.mov`.
Successful MOV files are removed after validation.

## Validation levels

| Level | Rounds | Fixture Host attempts | When to run |
| --- | ---: | ---: | --- |
| Smoke | 1 | 1 Scenario × 1 round | Quick end-to-end check after routine changes |
| Regression | 3 | 1 Scenario × 3 rounds | Changes to Control, AX, Recorder, process lifecycle, or Scenario runner |
| Reliability | 20 | 1 Scenario × 20 rounds | Before treating a version as stable |

Ordinary code changes need Core CI only. For race, cleanup, or lifecycle fixes,
run the Fixture Host at Regression level. Run Reliability level before a
stage-level stability decision.

## WiFi Lens product integration

Do not add WiFi Lens product checks to AppStage Core CI. When validating the
real product, build the WiFi Lens Pro app and point the same local commands at
that app:

```sh
WIFI_LENS_PRO_APP="/path/to/WiFi Lens Pro.app"
OUTPUT_ROOT="$HOME/Desktop/AppStage-Verify"

.build/debug/appstage doctor --app "$WIFI_LENS_PRO_APP" --json \
  --output "$OUTPUT_ROOT/environment.json"

.build/debug/appstage verify \
  --app "$WIFI_LENS_PRO_APP" \
  --iterations 3 \
  --retain-movies failures \
  --output "$OUTPUT_ROOT"
```

The current WiFi Lens Pro integration automatically discovers `roaming-handoff`,
`heatmap-demo`, `ap-radar-tracking`, and `channel-recommendation`. Use 3 rounds
before producing a batch of product footage; use 20 rounds when additional
confidence is needed.

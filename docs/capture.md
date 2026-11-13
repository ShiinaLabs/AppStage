# Capture

AppStage provides these capture commands:

- `snapshot` writes a PNG of a running app window with transparent framing around it.
- `capture-snapshot` launches one controlled Scenario, prepares a static capture point, and writes a PNG.
- `capture-all-snapshots` discovers and captures every Host-declared static capture point to PNGs and `manifest.json`.
- `record` launches and records one Scenario to a MOV.
- `capture-all` discovers Scenarios and writes one MOV for each, plus `manifest.json`.
- `verify` repeats every discovered Scenario in fresh processes and validates each MOV.

## Static scenario screenshots

Hosts list supported capture point IDs in each `StageScenarioMetadata`. A capture
point is a named, deterministic visible result. The Host implements
`prepareCapture(at:)` to establish that result and returns only when it is ready;
AppStage does not seek playback by timestamp or use a fixed delay to guess UI
readiness.

Capture one point:

```sh
appstage capture-snapshot --app "/Applications/Example.app" \\
  --scenario overview --checkpoint summary --output ./Artifacts/summary.png
```

Capture all advertised points sequentially, each in a fresh process:

```sh
appstage capture-all-snapshots --app "/Applications/Example.app" \\
  --output-dir ./Artifacts/snapshots
```

The batch command writes a PNG and manifest entry for each point. It continues
after an individual failure and exits unsuccessfully after writing the final
manifest if any point failed. PNG commands use a fixed canvas with transparent
margins by default. Add `--native-size` to write the system window screenshot at
its native dimensions without extra margins; the margin options are ignored in
this mode. For example:

```sh
appstage capture-snapshot --app "/Applications/Example.app" \
  --scenario overview --checkpoint summary --native-size \
  --include-window-shadow --output ./Artifacts/summary.png
```

`--include-window-shadow` controls whether the system-rendered shadow is included
in those dimensions. Native-size screenshots cannot include the separate AppStage
demo cursor overlay; omit `--include-demo-cursor` when using this mode. The mode
is available on `snapshot` and the controlled screenshot commands, including
`capture-all-snapshots`. Set `defaults.captureAllSnapshots.nativeSize` to `true`
in a case plan to enable it for batch screenshots by default.

## Single recording

```sh
appstage record --app "/Applications/Example.app" \
  --scenario walkthrough --output ./Artifacts/walkthrough.mov
```

`record` starts a controlled process with `--appstage-scenario`. Use
`--keep-app-running` when a single recording should leave its launched app
running afterward.

For a transparent ProRes 4444 master, add `--transparent-background`:

```sh
appstage record --app "/Applications/Example.app" \
  --scenario walkthrough --transparent-background \
  --output ./Artifacts/walkthrough-transparent.mov
```

This writes a QuickTime MOV with an alpha channel. The default remains H.264
with an opaque black background. `--transparent-background` cannot be combined
with `--background-image`; use one mode per recording.

## Batch recording

```sh
appstage capture-all --app "/Applications/Example.app" \
  --output-dir ./Artifacts/batch
```

`capture-all` runs a discovery process, closes it, then starts one fresh process
per Scenario. It records Scenarios sequentially and writes one MOV for each.
The discovery process and every Scenario process are closed as their round
finishes. This isolates UI state and avoids cross-Scenario navigation or focus
contamination. It neither reuses one app process to switch Scenarios nor records
multiple Scenarios in parallel.

Use the same flag for transparent batch masters:

```sh
appstage capture-all --app "/Applications/Example.app" \
  --transparent-background --output-dir ./Artifacts/batch
```

## Case plans and suites

A versioned JSON case plan lets a Host's reusable Scenario and capture point IDs
be selected without a wrapper script. Cases only reference Host declarations;
the Host still owns Scenario behavior, product data, static UI preparation, and
business assertions.

```json
{
  "schemaVersion": 1,
  "cases": [
    { "id": "overview", "scenarioID": "overview" },
    { "id": "settings", "scenarioID": "settings" },
    { "id": "overview-summary", "scenarioID": "overview", "capturePointID": "summary" }
  ],
  "suites": {
    "recordings": ["overview", "settings"],
    "snapshots": ["overview-summary"],
    "smoke": ["overview"]
  },
  "defaults": {
    "captureAll": {
      "outputDirectory": "./Artifacts/movies",
      "timeoutSeconds": 45,
      "frameRate": 30,
      "transparentBackground": true
    },
    "captureAllSnapshots": {
      "outputDirectory": "./Artifacts/snapshots",
      "includeWindowShadow": true
    },
    "verify": {
      "outputDirectory": "./Artifacts/verify",
      "iterations": 3,
      "retainMovies": "failures"
    }
  }
}
```

Save it as `appstage-cases.json`. Relative output and background image paths in
the plan resolve from that file's directory. Each batch command selects a suite
whose cases match its target type:

```sh
appstage capture-all --app "/Applications/Example.app" \
  --config ./appstage-cases.json --suite recordings
appstage capture-all --app "/Applications/Example.app" \
  --config ./appstage-cases.json --suite recordings --filter 'over*' --exclude '*settings*'
appstage capture-all-snapshots --app "/Applications/Example.app" \
  --config ./appstage-cases.json --suite snapshots
appstage verify --app "/Applications/Example.app" \
  --config ./appstage-cases.json --suite smoke --iterations 5
```

Repeat `--filter` and `--exclude` to provide multiple `*` / `?` glob patterns.
Include patterns are ORed, then excluded matches are removed; filtering preserves
suite order and cannot add cases. Configured values are defaults; explicit CLI
options take precedence. Use `--no-transparent-background`, `--no-background-image`,
`--no-window-shadow`, `--no-native-size`, and `--no-demo-cursor` to turn off
corresponding enabled configuration defaults. The selected order is explicit `--suite`, then
`defaultSuite`, then the case list order. A suite may contain Scenario cases for `capture-all` and
`verify`, or capture point cases for `capture-all-snapshots`; selecting a case of
the wrong kind, an unknown Host reference, or no cases is an error before output
is created. Without a case plan, batch commands keep running all discovered items.

## Reliability verification

```sh
appstage verify --app "/Applications/Example.app" \
  --iterations 20 --output ~/Desktop/AppStage-Verify
```

`verify` discovers the Host's Scenarios, then runs each one sequentially in a
fresh controlled process for every iteration. It records per-attempt lifecycle
events, PID and exit status, cleanup state, and MOV validation results. AVFoundation
reopens each MOV and checks for a readable video track, positive duration and
dimensions, at least two frames with increasing presentation timestamps, and a
minimum file size. Any failed attempt makes the command exit non-zero.

With `--transparent-background`, verification also decodes BGRA frames and
requires both transparent and visible alpha pixels:

```sh
appstage verify --app "/Applications/Example.app" \
  --transparent-background --iterations 1 --retain-movies all \
  --output ~/Desktop/AppStage-Verify
```

Use `--retain-movies failures|all|none` to control the verified video output.
The default is `failures`: passed recordings are removed after validation and
failed recordings are kept when available.

Each invocation creates a timestamped `run-*` directory containing
`summary.json`, `summary.txt`, and per-scenario `attempt-*` folders with
`result.json`, `trace.json`, and `recording.mov`. `summary.json` uses schema
version 2 and records the plan path, selected suite and case IDs, filters, and
effective timeout, retention, and video output settings. Failed attempts also
include `diagnostics.json`.

Control Protocol v4 does not report Host-internal condition IDs or detailed AX
snapshots. The current report marks those telemetry sources unavailable rather
than inferring them from video or treating a successful command as evidence.

Before a local reliability run, use `doctor` to check the GUI session, macOS
version, Accessibility and Screen Recording permissions, display, target
bundle, stale target processes, available disk space, Xcode, and Swift:

```sh
appstage doctor --app "/Applications/Example.app" --json \
  --output ./Artifacts/environment.json
```

Each Scenario starts with its ID in `--appstage-scenario`, so the Host can choose
its initial route and state at launch. The Host does not need runtime navigation
between Scenarios.

## Framing and canvas

Video capture uses strict framing: the complete app window and requested
desktop margins must fit on one display. If they do not, capture fails instead
of silently clipping or shrinking the requested framing. Adjust the window or
requested margins explicitly.

Use `--background-image ./Artifacts/background.png` to composite each captured
frame over a fixed image. The image's pixel dimensions determine the output
canvas. The output directory must be empty when capture starts.

Transparent MOVs are intended for compositing in a video editor: place the
background on a lower video track and the AppStage recording above it. The
recording retains the captured app window and its transparent framing area;
`verify --transparent-background` confirms alpha data is present. Do not use
chroma-key or luma-key effects for this output.

On DaVinci Resolve 21.0.3.7, the imported ProRes 4444 clip is correctly
interpreted with **Clip Attributes → Alpha Mode → Straight**. This was visually
verified at multiple points in the recording over a magenta/cyan background:
the background shows through around the app window while its rounded corners,
shadow, and cursor remain intact. For other Resolve versions, check the imported
clip over a high-contrast background before delivery.

## Manifest and failures

Recording and snapshot `manifest.json` files use schema version 2 and are
updated as the batch proceeds. They record the case plan path, selected suite,
filter patterns, and each selected case ID alongside its Host target and status.
Recording entries use `pending`, `recording`, `completed`, `failed`, or
`cancelled`; snapshot entries use `pending`, `capturing`, `completed`, `failed`,
or `cancelled`.

Batch capture fails fast. If a Scenario fails, its incomplete MOV is removed,
previously completed MOVs are retained, and later Scenarios remain pending. On
cancellation, the current recorder and process are cleaned up, the current MOV
is discarded, completed outputs are retained, and later Scenarios do not run.

## Permissions

macOS requires Screen Recording permission for screen capture. Accessibility
permission is required for real AX interaction with controls.

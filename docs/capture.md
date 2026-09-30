# Capture

AppStage provides four capture commands:

- `snapshot` writes a PNG of a running app window with desktop around it.
- `record` launches and records one Scenario to a MOV.
- `capture-all` discovers Scenarios and writes one MOV for each, plus `manifest.json`.
- `verify` repeats every discovered Scenario in fresh processes and validates each MOV.

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
`result.json`, `trace.json`, and `recording.mov`. Failed attempts also include
`diagnostics.json`.

Control Protocol v3 does not report Host-internal condition IDs or detailed AX
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

`manifest.json` uses schema version 1 and is updated as the batch proceeds. It
records each Scenario as `pending`, `recording`, `completed`, `failed`, or
`cancelled`, plus the batch status.

Batch capture fails fast. If a Scenario fails, its incomplete MOV is removed,
previously completed MOVs are retained, and later Scenarios remain pending. On
cancellation, the current recorder and process are cleaned up, the current MOV
is discarded, completed outputs are retained, and later Scenarios do not run.

## Permissions

macOS requires Screen Recording permission for screen capture. Accessibility
permission is required for real AX interaction with controls.

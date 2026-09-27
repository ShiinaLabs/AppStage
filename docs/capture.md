# Capture

AppStage provides three capture commands:

- `snapshot` writes a PNG of a running app window with desktop around it.
- `record` launches and records one Scenario to a MOV.
- `capture-all` discovers Scenarios and writes one MOV for each, plus `manifest.json`.

## Single recording

```sh
appstage record --app "/Applications/Example.app" \
  --scenario walkthrough --output ./Artifacts/walkthrough.mov
```

`record` starts a controlled process with `--appstage-scenario`. Use
`--keep-app-running` when a single recording should leave its launched app
running afterward.

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

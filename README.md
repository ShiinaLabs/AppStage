# AppStage

AppStage is a deterministic demo-capture framework for macOS apps. A host app
defines repeatable scenarios; AppStage drives them and records clean PNG and
MOV assets from the command line.

## What it does

- Runs deterministic demo scenarios.
- Shows cursor movement and interaction feedback.
- Uses real macOS Accessibility actions for visible UI controls.
- Captures screenshots and MOV recordings.
- Composes recordings onto a custom video canvas.
- Records batches with a fresh app process for each scenario.
- Repeats discovered scenarios with `appstage verify` and validates each MOV.

## How it works

`Host scenario → AppStage control → visible interaction → screen capture → PNG / MOV`

## Example

```sh
appstage record --app "/Applications/Example.app" --scenario walkthrough \
  --output ./Artifacts/walkthrough.mov

appstage capture-all --app "/Applications/Example.app" \
  --output-dir ./Artifacts/batch

appstage verify --app "/Applications/Example.app" \
  --iterations 1 --retain-movies failures \
  --output ~/Desktop/AppStage-Verify
```

## Documentation

- [Getting started](docs/getting-started.md)
- [Designing scenarios](docs/scenarios.md)
- [Capture commands and output](docs/capture.md)
- [AppStage Reliability Validation](docs/reliability.md)

## Requirements

macOS 14 or later, Screen Recording permission, and Accessibility permission for real AX interaction.

## License

AppStage is licensed under the Apache License 2.0. See LICENSE.

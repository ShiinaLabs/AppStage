# AppStage

AppStage is a product-neutral test runner for repeatable macOS app experiences.
Host apps register Cases and own deterministic behavior; AppStage selects and
executes Cases and coordinates output Artifacts such as PNG and MOV files.

## What it does

- Runs deterministic demo scenarios.
- Shows cursor movement and interaction feedback.
- Uses real macOS Accessibility actions for visible UI controls.
- Captures screenshots and MOV recordings.
- Composes recordings onto a custom video canvas.
- Runs UI work sequentially with process isolation where required.
- Validates recorded MOV outputs with `appstage verify`.

Current batch commands still discover through a launched Host process and route
recording and snapshots through separate workflows. These are documented gaps;
see [Architecture](docs/architecture.md).

## How it works

`register Cases → select by suite/filter → execute selected Cases → produce Artifacts → report results`

See [Architecture](docs/architecture.md) for the Case, Scenario, Artifact, and
Run model, including current implementation gaps.

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

- [Architecture](docs/architecture.md)
- [Getting started](docs/getting-started.md)
- [Designing scenarios](docs/scenarios.md)
- [Capture commands and output](docs/capture.md)
- [AppStage Reliability Validation](docs/reliability.md)

## Requirements

macOS 26 or later. Building from source requires Swift tools 6.2 or later.
Screen Recording permission is required for capture, and Accessibility
permission is required for real AX interaction.

## License

AppStage is licensed under the Apache License 2.0. See LICENSE.

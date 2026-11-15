# AppStage Agent Guide

## Project purpose

AppStage is a product-neutral test runner for repeatable macOS app experiences.
Host apps register Cases and own deterministic behavior; AppStage selects and
executes Cases and coordinates output Artifacts. Read [the architecture](docs/architecture.md)
for the intended model and the current implementation gaps.

## Scope boundary

AppStage provides deterministic scenarios, control, visible cursor feedback,
Accessibility interaction, ScreenCaptureKit capture, screenshots, custom video
canvas composition, single recording, sequential batch recording, and a capture
manifest. It does not provide editing, timeline, transitions, captions, audio,
music, final-video assembly, or general computer use.

## Source layout

- `Sources/AppStage/` — scenario definitions, actions, cues, playback, and launch configuration.
- `Sources/AppStageMac/` — macOS window configuration and demo cursor.
- `Sources/AppStageControl/` — Host control client, protocol, and session state.
- `Sources/AppStageCapture/` — ScreenCaptureKit, screenshots, video recording, and canvas composition.
- `Sources/AppStageOrchestration/` — controlled Host process sessions, accessibility control, and app lifecycle.
- `Sources/AppStageCLI/` — `appstage` commands and capture workflows.
- `Tests/` — module-level and CLI tests.

## Read first

- Always follow [.agents/guardrails.md](.agents/guardrails.md).
- When changing Scenario/Core, read [.agents/architecture.md](.agents/architecture.md) and [.agents/host-integration.md](.agents/host-integration.md).
- When changing capture, read [.agents/capture-pipeline.md](.agents/capture-pipeline.md).
- When changing batch behavior, read [.agents/capture-pipeline.md](.agents/capture-pipeline.md) and [docs/capture.md](docs/capture.md).
- When integrating a new Host, read [.agents/host-integration.md](.agents/host-integration.md) and [docs/getting-started.md](docs/getting-started.md).
- For Scenario authoring, read [docs/scenarios.md](docs/scenarios.md).

## Invariants

- AppStage is product-neutral; Host-specific code and strings stay in the Host.
- The Host owns Case registration, deterministic data providers, and product behavior.
- A Case is the selection and reporting unit. A Scenario is reusable Host behavior, not a page or route; process isolation is an execution policy.
- Discovery must not show product UI or execute Cases. Current batch workflows launch a discovery process before filtering; this is a known gap, not an invariant.
- Batch execution is sequential. Never execute two UI Cases at once.
- Visible macOS controls use Accessibility interaction. Hidden deterministic transitions may use semantic actions.
- Do not synthesize physical `CGEvent` input without a demonstrated requirement.
- Fail closed when capture quality or complete-frame writing cannot be maintained.
- Do not add video editing or final-assembly responsibilities.
- Use the latest Control Protocol and manifest schema only; do not add backward compatibility for older versions.

## Tests and verification

- Keep tests small and focused on stable behavior.
- AppStage changes: run `swift test` and `swift build --product appstage`.
- Host integration changes: run targeted tests and Debug builds for affected editions.
- Validate real ScreenCaptureKit behavior with a smoke capture; do not try to mock the entire capture stack.
- Do not run broad Host business suites for small integration edits.

## Integration boundary

For Case execution, the Host chooses deterministic state and any required
initial route from launch configuration. AppStage coordinates the Case lifecycle
and its Artifact producers; it must never learn Host navigation, domain models,
or product-specific content. Registration/discovery must not require a visible
product window.

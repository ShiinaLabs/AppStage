# Getting started

This guide connects a macOS app to AppStage and records its first controlled
Scenario.

## 1. Add the Swift package

Add the AppStage package to the Host project. Import only the products the Host
uses:

- `AppStage` for Scenario IDs, scripts, actions, and conditions.
- `AppStageMac` for controlled window setup and the visible demo cursor.
- `AppStageControl` for the Host-side `StageControlClient`.
- `AppStageCapture` and the `appstage` CLI are normally used by the capture tool, not the Host.

## 2. Read launch configuration at startup

Parse AppStage arguments once during process startup, before selecting the
window's first route or creating Scenario-specific state:

```swift
let launch = try StageLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
```

Use `launch.scenarioID` to select a controlled Scenario, or
`launch.discoverScenarios` for discovery. The control endpoint is present when
`controlHost`, `controlPort`, `controlToken`, and `controlSession` are all set.

## 3. Detect a controlled session

Treat a launch with a Scenario ID or discovery enabled as controlled. Keep this
mode isolated from ordinary app behavior, user preferences, live services, and
external side effects.

## 4. Provide deterministic data

Create controlled providers that return stable fixture data and known state
transitions. Do not make a capture depend on nearby hardware, live network
conditions, user permissions, or changing account data.

## 5. Create the Scenario runtime

Build a runtime that registers the available Scenario metadata, scripts,
semantic actions, Accessibility targets, and readiness conditions. Keep all
product-specific models and navigation inside the Host.

## 6. Connect the control client

Create `StageControlClient` with the parsed loopback endpoint, token, session ID,
and Host bundle identifier. Connect it only after the controlled runtime and
main window are ready to accept control.

## 7. Configure the controlled window

Apply a deterministic window size and initial placement for controlled runs.
The Host selects its initial UI route from the launch Scenario ID before its
first visible layout.

## 8. Implement one Scenario

Start with one Scenario that can load, prepare, play, and reset from a known
state. Make preparation wait for all data and first-interaction readiness; see
[Scenario design](scenarios.md).

## 9. Record it

Build the Host app, then run:

```sh
appstage record --app "/Applications/Example.app" \
  --scenario walkthrough --output ./Artifacts/walkthrough.mov
```

The Host receives control requests through `StageControlClient`; AppStage
starts recording after the Host reports ready and stops when the Scenario
finishes.

## 10. Record all Scenarios

Once the Host can list and independently start its Scenarios, capture a batch:

```sh
appstage capture-all --app "/Applications/Example.app" \
  --output-dir ./Artifacts/batch
```

Batch capture discovers once, then uses a new Host process for each Scenario in
order. See [Capture](capture.md) for outputs, framing, and failure behavior.

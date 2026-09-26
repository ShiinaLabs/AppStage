# AppStage

AppStage provides generic scenario playback, macOS window layout, and screen
capture for automated app demonstrations. Product-specific scenarios and data
providers belong in the host application; AppStage does not depend on any
particular product.

## Package targets

- AppStage: scenario identifiers, deterministic sequences, launch arguments,
  and clock-driven playback.
- AppStageMac: host-app window size and positioning.
- AppStageCapture: ScreenCaptureKit discovery, screenshots, and MOV recording.
- AppStageCLI: the appstage command-line tool.

## Commands

List running applications visible to ScreenCaptureKit:

~~~sh
appstage list
~~~

Capture a PNG around an already-running app window:

~~~sh
appstage snapshot \
  --bundle-id com.example.application \
  --output ./Artifacts/snapshot.png
~~~

Launch an app with scenario arguments, then capture a MOV:

~~~sh
appstage record \
  --app "/Applications/Example.app" \
  --scenario walkthrough \
  --duration 10 \
  --output ./Artifacts/walkthrough.mov
~~~

The target app receives --appstage-scenario, --appstage-autoplay, and
--appstage-window arguments. It can parse them with StageLaunchConfiguration.
Recording uses a one-second startup warm-up before capture begins.

AppStage uses ScreenCaptureKit for window discovery and display capture. macOS
may require Screen Recording permission for the appstage executable.

## Build and test

~~~sh
swift build
swift test
~~~

## License

AppStage is licensed under the Apache License 2.0. See LICENSE.

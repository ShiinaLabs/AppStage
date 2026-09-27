# Guardrails

Keep AppStage focused on stable, repeatable macOS demo capture. Do not add any
of the following without a concrete product need:

- Timeline or an editor.
- Video editing, transitions, captions, audio, music, or final-video assembly.
- Physical `CGEvent` input or general Computer Use.
- Parallel Scenario recording.
- Automatic retries.
- Automatic FPS downgrade.
- Automatic framing-margin adjustment.
- Dynamic bitrate tuning.
- Host-specific navigation or product strings in AppStage.
- Control Protocol version bumps without a compatibility requirement.
- Capture manifest schema bumps without a compatibility requirement.

## Verification policy

- Keep tests minimal and focused on high-value behavior.
- For AppStage changes, run `swift test` and `swift build --product appstage`.
- For Host integration changes, run targeted tests and Debug builds for the
  affected editions. Avoid broad Host business suites for small changes.
- Real ScreenCaptureKit behavior needs a smoke capture; do not try to mock the
  entire capture stack.
- Never report a build, test, or smoke as passing unless it completed and its
  output was inspected.

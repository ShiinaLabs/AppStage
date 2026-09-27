# Architecture

AppStage provides reusable macOS demo capture without importing Host product
types. The Host owns deterministic providers, Scenario content, and initial UI
state.

## Modules

| Module | Owns | Does not own |
|---|---|---|
| `AppStage` | Scenario IDs and metadata, scripts, cues, semantic actions, async conditions, and playback state | Product models, navigation, or capture |
| `AppStageMac` | Controlled window configuration and visible demo cursor models | Host routes or physical mouse/keyboard input |
| `AppStageControl` | Control client/controller, session identity, state machine, loopback transport, and AX request contracts | Host UI or product behavior |
| `AppStageCapture` | ScreenCaptureKit discovery, screenshots, framing, canvas composition, and MOV recording | Editing or movie assembly |
| `AppStageCLI` | `list`, `scenarios`, `run`, `snapshot`, `record`, and `capture-all` orchestration | Host-specific Scenario definitions or navigation |

## Control and capture boundaries

```text
Host app ↔ loopback Control Channel ↔ appstage CLI
                                         ├─ Accessibility interaction
                                         └─ ScreenCaptureKit → PNG / MOV
```

The current Control Protocol is v3. It binds a session to a token, session UUID,
bundle identifier, and process ID. Keep v3 unless a concrete compatibility
requirement needs a protocol change; update both sides together when one is
necessary.

## Scenario lifecycle and action types

The Host implements `load → prepare → ready → play → finished`, and supports
reset for repeatability. `prepare` establishes deterministic model/data state
and, when needed, the first real Accessibility target. The Host's ready signal
means playback can begin safely now.

Semantic actions update deterministic internal state without presenting a
native UI intermediate. Accessibility interaction presses visible macOS
controls when the interaction itself matters to the recording. The cursor
provides visual feedback and does not synthesize physical input.

Host-specific code never belongs in AppStage. AppStage must not know the Host's
pages, routes, sidebars, models, or product strings.

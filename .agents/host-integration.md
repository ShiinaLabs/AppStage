# Host integration checklist

Use this checklist when adding AppStage to a macOS app.

1. Parse `StageLaunchConfiguration` from process arguments at startup.
2. Determine the `scenarioID`, `discoverScenarios` mode, and complete control
   endpoint from the parsed values.
3. For a controlled Scenario process, select its initial UI route and state at
   launch, before the first visible layout. Do not rely on runtime navigation
   from Scenario A to Scenario B.
4. Supply deterministic providers for controlled data. Keep normal live
   providers unchanged outside controlled mode.
5. Ensure irrelevant live-environment gates cannot replace deterministic demo
   UI. Consider permissions, live hardware state, and network availability when
   the controlled provider already supplies a synthetic equivalent.
6. Register Scenario metadata and implement load, prepare, play, pause, and
   reset behavior as required by the Host's scripts.
7. Make prepare wait for data/model readiness and, when needed, the first real
   interaction target in the Accessibility tree.
8. Give interactive controls stable `accessibilityIdentifier` values and
   register identifier-based targets.
9. Connect `StageControlClient` only after the controlled runtime and Host
   window are ready.
10. Give the controlled window a deterministic size and placement.
11. Keep all Host navigation and domain behavior inside the Host. AppStage
    should know only `StageScenarioID` and Scenario metadata.

## Common pitfalls

| Pitfall | Fix |
|---|---|
| Model ready does not mean UI ready. | Wait for the first real target when the Scenario begins with a native control. |
| Batch capture depends on runtime cross-Scenario navigation. | Start a fresh Host process for each Scenario. |
| A deterministic provider is still blocked by a live permission or hardware gate. | In controlled mode, bypass only the irrelevant presentation gate while preserving normal user behavior. |
| An AX identifier is correct but the target is absent. | Debug in this order: (1) process/PID, (2) startup Scenario, (3) expected UI visible, (4) live gate not replacing it, (5) AX element exists, then (6) accessibility grouping. |

Use condition-driven readiness, not fixed sleeps.

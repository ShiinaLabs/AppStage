# Scenario design

A Scenario is one deterministic unit of demo behavior and one recording unit.
It is not a page or route. One page may support several Scenarios, and a
Scenario may move through several parts of the Host UI.

## Start from known state

Each Scenario should reset its providers and models to a deterministic initial
state. Repeating the same Scenario should produce the same meaningful content
and interaction sequence.

The usual lifecycle is:

```text
load → prepare → ready → play → finished
```

- **load** selects the Scenario script and resets its state.
- **prepare** establishes data and UI readiness without starting playback.
- **ready** means the Scenario can safely begin immediately.
- **play** runs the scripted sequence.
- **finished** signals that all intended demo actions completed.

## Choose the right interaction

1. **Semantic actions** make stable internal state changes that do not need a
   visible macOS interaction in the material. Examples include loading a
   deterministic fixture or advancing an internal data source.
2. **Accessibility interaction** is for controls whose real UI state change
   should appear in the recording, such as a Button, Picker, Menu, or MenuItem.
3. **Visual cursor interaction** shows movement, hover, or click feedback. It
   can accompany semantic or Accessibility actions; by itself it does not
   activate a native control.

Choose the interaction that makes the material clear and repeatable. Realism
serves the asset, rather than dictating the Host's architecture.

## Readiness is a contract

`prepare` must wait for the Scenario's data and model to be ready. If the first
scripted operation depends on a real Accessibility element, also wait until
that first interaction target exists in the Host accessibility tree.

When the Host reports ready, the Scenario should be safe to play immediately.
A model-ready flag alone does not prove that the visible control exists. Do not
replace readiness conditions with a fixed sleep; wait for the state or target
that playback actually needs.

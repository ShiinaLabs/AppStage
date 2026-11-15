# Architecture reference

The architecture source of truth is [docs/architecture.md](../docs/architecture.md).
It defines the intended Google Test-like model: Case registration, suite/filter
selection, Case execution, Artifact production, and Run reporting.

Before changing code, distinguish that target from current implementation. In
particular, discovery still launches a Host process, batch recording selects
Scenario cases separately from snapshot capture-point cases, and output handling
uses separate workflows. These are known gaps, not invariants to preserve.

The current package/module map, Host ownership rules, lifecycle protocol, and
Artifact responsibilities are documented in the architecture source of truth.
See [Host integration](host-integration.md), [capture pipeline](capture-pipeline.md),
and [user capture guide](../docs/capture.md) for the detailed implementation contracts.

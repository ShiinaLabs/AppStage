# Reliability CI

AppStage separates non-GUI correctness from GUI reliability checks.

## GitHub-hosted Core CI

`.github/workflows/ci.yml` runs on pull requests and pushes to `main`. It
resolves Swift packages, builds and tests the package, and builds the Release
configuration. It does not launch a host app or request Accessibility or Screen
Recording access. The `AppStage Core CI` job is the initial branch-protection
check.

## Self-hosted GUI reliability

`.github/workflows/reliability.yml` runs the in-repository
`Fixtures/AppStageTestHost` app with its single `reliability-smoke` Scenario. It
builds AppStage from the current checkout through a local Swift package
reference, checks the runner with `appstage doctor`, then runs `appstage verify`.
The workflow serializes access to the GUI runner under the `appstage-gui`
concurrency group and skips fork pull requests.

The round count is one for same-repository pull requests, three for pushes to
`main`, and twenty for the nightly run. Successful MOV files are deleted after
validation. Failed attempt reports and recordings are uploaded for seven days.
The self-hosted check is intentionally not a required branch-protection check
until the runner has demonstrated stable operation.

The runner must be a logged-in macOS GUI user with Accessibility and Screen
Recording permissions, an active display, Xcode, and at least 10 GB free. Keep
the runner awake during jobs. `appstage doctor --json --output environment.json`
records the environment and returns non-zero for infrastructure failures, so a
doctor failure is distinct from an AppStage verification regression.

## Product integration

AppStage Core CI and its GUI fixture do not check out or depend on WiFi Lens.
Product integration belongs in the WiFi Lens repository. That repository does
not currently expose an `appstage-integration` build product or the four named
AppStage Scenario IDs, so its self-hosted integration workflow must wait until
that integration exists. Do not treat an absent integration workflow as a
passing product gate.

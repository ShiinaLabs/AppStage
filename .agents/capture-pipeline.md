# Capture pipeline

## Single Scenario recording

```text
launch controlled process
→ Control handshake
→ load Scenario
→ prepare
→ ready
→ discover target window and display
→ start recorder and wait for first complete frame
→ play
→ race Host finished against recorder failure
→ stop and finalize MOV
→ close controller and process
```

The recorder failure wins if capture becomes unhealthy before Host completion.
Cancellation stops the recorder, discards its owned incomplete MOV, and closes
the controller and launched process. A single `record` may keep its app running
when `--keep-app-running` is requested.

## Batch recording

`capture-all` prepares an empty output directory, starts one discovery process,
lists metadata, then closes the discovery controller and process. After
preflight, it processes metadata in order:

```text
for each Scenario:
    new token + session UUID + controller + workflow + Host PID
    launch with --appstage-scenario <id>
    load → prepare → record → finish → finalize MOV → close
```

Only one round runs at a time. No controller, token, session UUID, or process is
shared across rounds. PID diagnostics belong in verification output, never in
the production manifest.

## Screen capture and video

ScreenCaptureKit uses an application-only filter tied to the controlled Host's
PID and bundle identifier. Video framing is strict and keeps the complete
window plus requested margins on one display. Legacy screenshot capture clips
to the available display bounds.

Without a canvas, complete ScreenCaptureKit samples go directly to the MOV
writer. With a canvas:

```text
ScreenCaptureKit BGRA frame
→ StageFrameCompositor source-over fixed background
→ pixel-buffer adaptor
→ H.264 QuickTime MOV
```

Writer backpressure, missing complete-frame data, compositor failure, and other
fatal writer errors fail the recording. Never silently drop complete frames or
retry with degraded quality.

## Outputs and manifest

The recorder owns only an MOV it successfully started. Failure and cancellation
remove that incomplete output; successful finalize releases recorder ownership.
The batch workflow owns `manifest.json`, writes it atomically after each state
change, preflights IDs and filenames before recording, and stops at the first
failure. Completed files remain; the failed file is marked failed and later
entries remain pending. Manifest schema remains v1.

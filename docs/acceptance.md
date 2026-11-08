# Device acceptance checklist

Scenarios that can only be checked on a real iPhone. Install with `make device`, run each row, then fill in Result (pass, fail with a note, or "not run") and Date. Spec refers to `hippo-v0-spec.md`; design refers to `docs/superpowers/specs/2026-11-07-hippo-v0-design.md`.

| # | Scenario | Steps | Expected | Result | Date |
|---|---|---|---|---|---|
| 1 | Spec 14.1, offline screenshot (local part; upload waits for Plan 3) | Airplane mode on. Share a screenshot from Photos to Hippo. Open Hippo. | Sheet shows "✓ Saved on this iPhone". The screenshot is in the timeline as "On iPhone". | not run | |
| 2 | Spec 14.2, round trip of each kind (local part) | Share each to Hippo: a URL only, a PDF, an audio file, a large video, and a mix of several attachments. Type a note with the Note button. Open each in Detail. | Each is one capture with the right grouping. Attachments open with correct content and sizes. Video plays. | not run | |
| 3 | Spec 14.3, crash after commit, before index insert (smoke check only; crash-after-commit is covered by the HippoKit recovery tests) | Save a capture and force-quit the app immediately. Relaunch. | The capture appears exactly once. | not run | |
| 4 | Spec 14.5, missing permission or metadata | Deny location, share from an app that gives no title or source. | Capture still saves. No location or source is shown or invented. | not run | |
| 5 | Spec 14.8, local search and filter offline (the 10k-capture scale check in 14.8 needs a generated dataset and is deferred to a later plan) | Airplane mode on. Search by text, use the chips and the Filters sheet. | Results are correct and responsive offline. | not run | |
| 6 | Spec 14.12, local deletion (local part) | Open a capture, Delete from iPhone. Try it while a sync is running. | The capture disappears locally. No crash. The prompt says copies already uploaded stay where they are. | not run | |
| 7 | Design V1, 30 s voice note offline | Airplane mode on. Record 30 s. Save. | Appears in the timeline with its duration. Plays back in Detail. Upload and byte match wait for Plan 3. | not run | |
| 8 | Design V2, interrupted recording | Start recording. Trigger an incoming call or Siri. | A valid partial recording is offered and saved. Nothing is half-committed. | not run | |
| 9 | Design V3, source clues from three apps | Share from three different apps (for example Safari, Photos, Files). Run `make diagnostics` or pull the developer-folder copy, and open each `metadata.json`. | `source_application` is null. `metadata_observations` has the type-identifier clues. | not run | |
| 10 | Design V4, reinstall keeps data | With captures present, rerun `make device` over the install. | All captures and queue state are intact. | not run | |
| 11 | Share Extension reads last-known location (spec 7) | Turn on "Save location with captures" in Settings and allow permission. Share something from Safari. Inspect the capture's `metadata.json` through the developer-folder copy (`HippoDevRemote/` in the App Group container) or with `make diagnostics`. | The share has a last-known location, or none if iOS has no recent fix. It never blocks the save. | not run | |
| 12 | Detail: PDF preview | Open a capture with a PDF. Tap the PDF card. Tap Done with a real finger. | QuickLook opens, and Done dismisses it. | not run | |
| 13 | Detail: playback with the silent switch | Ring/silent switch on silent. Play a voice note, then a video. Play music in another app first. | Both are audible. After playback stops, the other app's music resumes. | not run | |
| 14 | Detail: delete | Open a capture. Tap the menu, then "Delete from iPhone...". Tap Delete. | A confirmation dialog appears. After Delete the capture is gone from the timeline. | not run | |
| 15 | Detail: retry failed sync | Get a row to a failed sync state. Tap Retry in Detail. | A sync starts and the state changes. | not run | |
| 16 | Recorder: real microphone | Tap Record, speak, Stop, Save. Open the capture. | A voice note is saved and plays back with your voice. | not run | |
| 17 | Recorder: interruption message | Record, then trigger a phone call or Siri. | "Recording stopped by an interruption..." is shown. The saved duration is non-zero. | not run | |
| 18 | Recorder: cancel while recording | Start recording. Tap Cancel. | "Discard recording?" is asked. Keep recording continues it. Discard saves nothing. | not run | |
| 19 | Share: Safari URL and Photos image | Share a web page from Safari. Share an image from Photos. | Each shows "✓ Saved on this iPhone" and appears in the timeline. | not run | |
| 20 | Share: mixed with an unsupported item | Share a selection where one item is unsupported. | The inline notice appears. Save asks "Save the rest", and its Cancel returns to the sheet. | not run | |
| 21 | Settings: location permission | Turn on "Save location with captures". Deny the iOS prompt. | The prompt appears on first use. After denying, the footer says location is off in iOS Settings and Open Settings is shown. | not run | |
| 22 | Background sync | Connect the Developer folder. Save captures, background the app. Wait. Then check the device crash logs (Settings, Privacy & Security, Analytics & Improvements, Analytics Data, or Xcode, Devices, View Device Logs). | The captures eventually sync. The crash logs show no 0xdead10cc termination for Hippo. | not run | |
| 24 | Backlog drain | Connect the Developer folder with more than 200 captures waiting. Keep the app open. | All captures sync while the app stays open. | not run | |
| 23 | Install after 7-day expiry | After the free-team profile expires, run `make device`. | Captures are still there. | not run | |

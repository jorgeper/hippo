# Capture context, format 1.1, self-describing folder — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record factual context with every capture (audio route, device state, network, previous capture, location extras, motion, weather, barcodes, language, sounds, screenshot guess), version the format as major.minor (1.1), and upload the format documents into the destination so the folder describes itself.

**Architecture:** Capture-time facts are `metadata_observations` entries (`context.*`) and optional `capture_location` fields, built by pure code in `CaptureCore` from a plain `ContextSnapshot` that thin readers in `App/Shared` take when a capture begins; `HippoStore.capture` adds `context.enabled` and `context.burst`. Looked-up facts are six new `Enricher`s in the existing runner. `schema_minor` is an optional integer beside `schema_version` in all four document types. A `FormatUploader` in `SyncEngine` pushes bundled docs and schemas to `README.md` and `format/` when their digest changes.

**Tech Stack:** Swift 6.2, SwiftUI, Swift Testing (`@Test`), Vision, NaturalLanguage, SoundAnalysis, CoreMotion, Network, XcodeGen (`project.yml`), `uvx check-jsonschema` (`scripts/validate-fixtures.sh`).

**Spec:** `docs/superpowers/specs/2026-11-10-hippo-capture-context-design.md` (binding). Section numbers below (§) refer to it.

## Global Constraints

- Collecting context never delays, blocks or fails a save. No collector throws into the save path; an unreadable field is omitted; an entry with no readable field is omitted. No permission prompt from the Share Extension.
- Never rewrite `metadata.json`, `complete.json` or `content/` of a committed package. Every file already in Dropbox stays valid; an existing 1.0 fixture stays byte-identical.
- This build writes `schema_version` 1 and `schema_minor` 1. Readers accept any minor (missing = 0) and reject an unknown major.
- Observation keys and provenance, verbatim: `context.audio_route` / `av_audio_session`; `context.device` / `device_state`; `context.network` / `nw_path`; `context.burst` / `last_saved`; `context.enabled` / `settings`. Group names: `device_context`, `location`.
- Facet kinds and provenance, verbatim, each facet `version` 1: `motion_activity` / `core_motion`; `weather` / `open_meteo`; `barcodes` / `vision`; `language` / `natural_language`; `sound_classification` / `sound_analysis`; `screenshot` / `heuristic`. `motion_activity` and `weather` are off until switched on; the other four are on by default.
- Caps: strings in `context.*` ≤ 100 characters; ≤ 8 ports per direction; barcode `payload` ≤ 2,048 characters, ≤ 20 items per attachment; ≤ 60 motion segments; sound labels confidence ≥ 0.3, ≤ 8 per item; language skips text shorter than 20 characters.
- Copy, verbatim: Settings section "Context"; switches "Save device context with captures", "Motion activity", "Weather", "Barcodes and QR codes", "Language", "Sounds in recordings", "Screenshots"; device-context footer "Records the audio route (speaker, headphones, car), battery, network and the time since your last capture. Nothing leaves this iPhone except with your captures."; weather footer "Looks up the weather where and when you captured, for all your captures with a location. Sends an approximate location and the time to Open-Meteo.com. Weather data by Open-Meteo.com."; `NSMotionUsageDescription` "Hippo records whether you were still, walking, running, cycling or in a vehicle around the time of each capture."; folder README first line `<!-- Hippo folder README. Written by the Hippo app and replaced when the app updates. -->`; Detail section title "Context".
- Logs carry fixed codes only, never a signal value (no port name, coordinate, payload or label).
- Weather requests round coordinates to two decimals, go through `HTTPFetching`, and are paced to at most one per second. Tests never touch the network.
- Every new public type is `Sendable`; models stay `@MainActor` where their neighbours are. JSON keys are snake_case as in `CaptureMetadata`.
- Commit after each task with the `Co-Authored-By` and `Claude-Session` trailers in use on this branch. Read `git diff --cached` before each commit. Never commit `Hippo.xcodeproj`, `Config/Secrets.xcconfig` or `.env`, and never read or print the last two.
- `make test` green at the end of every task. Tasks 4, 9, 10, 11 and 13 also build the app (`xcodegen generate && xcodebuild -project Hippo.xcodeproj -scheme Hippo -destination 'generic/platform=iOS Simulator' build`); tasks 4 and 11 run `make uitest`; tasks 1, 2, 5 and 12 run `scripts/validate-fixtures.sh`.

## Review Focus

1. A share-sheet save where no `NWPath` has arrived, the route is unreadable and battery is unknown: the capture saves, has `context.enabled`, and has no empty `context.*` object (Task 2 `emptySnapshotYieldsNoEntries`; Task 3 `saveWithoutSnapshotStillSaves`).
2. A 1.0 package (no `schema_minor`) and a file with `schema_minor: 7` plus unknown keys both load, list and sync; a `schema_version: 2` file is still rejected (Task 1 tests; Task 12 `legacyFixturesHaveNoMinor`).
3. A user's own `README.md` already in the Dropbox folder is never overwritten, and its presence does not make every sync pass retry (Task 13 `foreignReadmeIsLeftAlone`).
4. A fix with `speed = -1`, `course = -1` or a non-finite altitude: the location is kept and only the bad extras are dropped (Task 2 `sanitizerDropsBadExtrasKeepsLocation`; Task 3 `pickCopiesOnlyValidExtras`).
5. A capture older than seven days when motion is switched on, and a capture made two minutes ago: neither writes a facet nor counts an attempt (Task 9 `expiredHistoryIsNotApplicable`, `recentCaptureIsDeferred`).

---

### Task 1: Format minor

**Files:**
- Create: `HippoKit/Sources/CaptureCore/Model/FormatVersion.swift`, `HippoKit/Tests/CaptureCoreTests/FormatVersionTests.swift`
- Modify: `HippoKit/Sources/CaptureCore/Model/CaptureMetadata.swift`, the file declaring `CompletionMarker`, `CaptureCore/Model/CaptureComment.swift`, `CaptureCore/Enrichment/EnrichmentDocument.swift`, `CaptureCore/Package/PackageWriter.swift`, `CaptureCore/Package/CommentWriter.swift`, every site that constructs an `EnrichmentDocument` for writing (grep `EnrichmentDocument(`), `schema/*.schema.json` (all four)

**Interfaces:**
- Produces:
  ```swift
  public enum FormatVersion { public static let major = 1; public static let minor = 1 }
  // On CaptureMetadata, CompletionMarker, CaptureComment, EnrichmentDocument:
  public var schemaMinor: Int?        // CodingKey "schema_minor"; nil when the file has none; encodeIfPresent
  ```
  Initializers gain `schemaMinor: Int? = nil` as a trailing defaulted parameter so existing call sites compile.

- [ ] **Step 1: Failing tests** in `FormatVersionTests.swift`:
  - `writerStampsMinor`: commit a package with `PackageWriter` → decoded `metadata.json` and `complete.json` have `schemaVersion == 1`, `schemaMinor == 1`; the raw JSON contains `"schema_minor":1` (or with a space, per the encoder).
  - `commentWriterStampsMinor`: `CommentWriter.add(.text("x"))` → `schemaMinor == 1`.
  - `legacyFilesDecodeWithNilMinor`: decode fixture package 1's `metadata.json` and `complete.json`, and fixture capture 2's `enrichment.json` → `schemaMinor == nil`; re-encoding produces no `schema_minor` key.
  - `higherMinorAndUnknownKeysDecode`: metadata JSON with `"schema_minor": 7` and an extra top-level key `"future_field": {"a": 1}` → decodes, `schemaMinor == 7`. Same for a comment and an enrichment document.
  - `unknownMajorRejected`: `"schema_version": 2, "schema_minor": 0` → `HippoJSON.decodeMetadata` and `decodeComment` throw `FormatError.unsupportedSchemaVersion` as today.
  - `negativeOrFractionalMinorRejected`: `"schema_minor": -1` and `1.5` fail decoding.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter FormatVersionTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Add the property and coding key to the four types (custom `init(from:)` only where one already exists; reject negative). `PackageWriter` and `CommentWriter` pass `FormatVersion.minor`. Every enrichment document this build writes (runner merge, any other writer found by the grep) is stamped `FormatVersion.minor`; a gold document read from the server keeps whatever it had.
- [ ] **Step 4: Schemas.** In each of the four `schema/*-v1.schema.json` add property `"schema_minor": { "type": "integer", "minimum": 0 }`, not required. File names unchanged.
- [ ] **Step 5: Run** the filter, `make test` and `scripts/validate-fixtures.sh`. Expected: PASS; existing fixtures untouched (`git status --short fixtures` empty).
- [ ] **Step 6: Commit** `feat(core): schema_minor, format 1.1`.

---

### Task 2: Capture-time context model

**Files:**
- Create: `HippoKit/Sources/CaptureCore/Context/ContextSnapshot.swift`, `HippoKit/Sources/CaptureCore/Context/ContextObservations.swift`, `HippoKit/Tests/CaptureCoreTests/ContextObservationsTests.swift`
- Modify: `CaptureCore/Model/CaptureMetadata.swift` (`CaptureLocation`), `CaptureCore/Package/DraftSanitizer.swift`, `HippoKit/Tests/CaptureCoreTests/` sanitizer tests, `schema/capture-metadata-v1.schema.json`

**Interfaces:**
- Produces:
  ```swift
  public struct ContextSnapshot: Sendable, Equatable {
      public struct Port: Sendable, Equatable { public var type: String; public var name: String? }
      public struct AudioRoute: Sendable, Equatable { public var outputs: [Port]; public var inputs: [Port] }
      public struct Device: Sendable, Equatable {
          public var batteryLevel: Double?          // 0...1
          public var batteryState: String?          // unplugged | charging | full
          public var lowPowerMode: Bool?
          public var thermalState: String?          // nominal | fair | serious | critical
          public var interfaceStyle: String?        // light | dark
          public var orientation: String?           // §4.2 values
          public var locale: String?
          public var uses24HourClock: Bool?
      }
      public struct Network: Sendable, Equatable {
          public var interface: String              // wifi | cellular | wired | other | none
          public var expensive: Bool; public var constrained: Bool
      }
      public var takenAt: Date
      public var audioRoute: AudioRoute?; public var device: Device?; public var network: Network?
      public init(takenAt: Date, audioRoute: AudioRoute? = nil, device: Device? = nil, network: Network? = nil)
  }
  public struct LastSaved: Codable, Sendable, Equatable { public var captureID: String; public var capturedAt: Date }
  public enum ContextKey {
      public static let audioRoute = "context.audio_route", device = "context.device",
                        network = "context.network", burst = "context.burst", enabled = "context.enabled"
  }
  public enum ContextObservations {
      public static let maxStringLength = 100, maxPorts = 8
      /// 0–3 entries in the order audio_route, device, network. Applies the caps; omits empty objects.
      public static func observations(from s: ContextSnapshot) -> [MetadataObservation]
      /// nil when `previous` is nil or the gap is negative. Seconds rounded to one decimal.
      public static func burst(previous: LastSaved?, capturedAt: Date) -> MetadataObservation?
      /// Always returns an entry; `groups` in the order device_context, location.
      public static func enabled(deviceContext: Bool, location: Bool) -> MetadataObservation
  }
  // CaptureLocation gains, all Double?, all defaulted nil in init, encodeIfPresent:
  //   altitudeMeters "altitude_meters", verticalAccuracyMeters "vertical_accuracy_meters",
  //   speedMetersPerSecond "speed_meters_per_second", speedAccuracyMetersPerSecond "speed_accuracy_meters_per_second",
  //   courseDegrees "course_degrees", courseAccuracyDegrees "course_accuracy_degrees"
  ```

- [ ] **Step 1: Failing tests** in `ContextObservationsTests.swift`:
  - `fullSnapshotMapsEveryField`: a snapshot with one output `car_audio`/"CarPlay", one input `built_in_mic`/"iPhone Microphone", every device field, network `wifi`/false/false → three entries with the keys and provenance from Global Constraints; values equal the JSON in §4.1–§4.3 (`port_type`, `port_name`, `battery_level`, `battery_state`, `low_power_mode`, `thermal_state`, `interface_style`, `orientation`, `locale`, `uses_24_hour_clock`, `interface`, `expensive`, `constrained`).
  - `emptySnapshotYieldsNoEntries`: `ContextSnapshot(takenAt:)` → `[]`; a `Device()` with every field nil → no `context.device`; a route with both arrays empty → no `context.audio_route`; a route with only outputs → the object has no `inputs` key.
  - `capsApplied`: 12 outputs → 8 kept in order; a 300-character port name → 100 characters; a 300-character `locale` → 100; a port with nil name → object has `port_type` only.
  - `nonFiniteBatteryOmitted`: `batteryLevel = .nan` and `1.7` → field omitted; `0.62` kept.
  - `burstMath`: previous at T, captured at T+41.24 → `{"previous_capture_id": id, "seconds_since_previous": 41.2}`, provenance `last_saved`; captured at T−1 → nil; previous nil → nil; gap 0 → entry with 0.
  - `enabledAlwaysWritten`: `(true, true)` → `groups == ["device_context", "location"]`; `(false, false)` → `groups == []`, provenance `settings`.
  - `locationExtrasRoundTrip`: a `CaptureLocation` with all six extras encodes the six keys; one with none encodes none and equals the decoded fixture-1 location shape.
  - `sanitizerDropsBadExtrasKeepsLocation` (in the sanitizer test file): extras `speed = -1`, `speedAccuracy = -1`, `course = 400`, `courseAccuracy = -1`, `altitude = .infinity`, `verticalAccuracy = -1` → location kept with all six nil and no `capture_location_dropped` observation; valid extras (`altitude = -12.5`, `speed = 0`, `course = 360`) survive.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter ContextObservationsTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Pure functions; build `JSONValue.object` by inserting only present fields. `DraftSanitizer`: altitude must be finite; vertical accuracy, speed, speed accuracy, course accuracy finite and ≥ 0; course finite and within 0...360; each bad extra is set to nil independently.
- [ ] **Step 4: Schema.** `capture-metadata-v1.schema.json`: the six optional number properties on `capture_location` (`course_degrees` min 0 max 360; accuracies and speed min 0).
- [ ] **Step 5: Run** the filter, `make test`, `scripts/validate-fixtures.sh`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(core): context snapshot, observations and location extras`.

---
### Task 3: Settings, policies and the store's context hooks

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Capture/ContextPolicy.swift`, `HippoKit/Sources/SyncEngine/CaptureContextHooks.swift`, `HippoKit/Tests/HippoPresentationTests/ContextPolicyTests.swift`, `HippoKit/Tests/SyncEngineTests/CaptureContextTests.swift`
- Modify: `HippoPresentation/Settings/AppSettings.swift`, `HippoPresentation/Capture/LocationPolicy.swift`, `SyncEngine/HippoStore.swift`, `HippoPresentation/Capture/RecorderModel.swift`, `HippoPresentation/Capture/NoteComposer.swift`, `HippoPresentation/Capture/CameraCapture.swift`, `HippoPresentation/Share/ShareSessionModel.swift`, `ShareIntake/ShareIntake.swift`, their tests

**Interfaces:**
- Consumes: `ContextSnapshot`, `ContextObservations`, `LastSaved`, `ContextKey` (Task 2).
- Produces:
  ```swift
  // AppSettings
  public var deviceContextEnabled: Bool { get nonmutating set }   // key "device_context_enabled"; unset = true
  public var lastSaved: LastSaved? { get nonmutating set }        // key "last_saved_capture", JSON data; undecodable = nil
  // LocationFix gains six Double? (altitude, verticalAccuracy, speed, speedAccuracy, course, courseAccuracy),
  // defaulted nil in init. LocationPolicy.pick copies each onto CaptureLocation only when valid (Task 2 rules).
  public enum ContextPolicy {
      public static let maxSnapshotAge: TimeInterval = 120
      /// [] when `enabled` is false. The snapshot is used when |takenAt − captureStartedAt| ≤ maxSnapshotAge;
      /// otherwise it is treated as absent. A missing network entry is filled from `networkAtSave`.
      public static func observations(enabled: Bool, snapshot: ContextSnapshot?, captureStartedAt: Date,
                                      networkAtSave: ContextSnapshot.Network?) -> [MetadataObservation]
  }
  public struct CaptureContextHooks: Sendable {
      public var enabledGroups: @Sendable () -> (deviceContext: Bool, location: Bool)
      public var lastSaved: @Sendable () -> LastSaved?
      public var recordSaved: @Sendable (LastSaved) -> Void
      public init(enabledGroups:lastSaved:recordSaved:)
  }
  // HippoStore.open(root:producer:process:context: CaptureContextHooks? = nil)
  // Capture paths: models that hold `location: (Date) -> CaptureLocation?` gain
  //   `context: @escaping (Date) -> [MetadataObservation] = { _ in [] }` beside it;
  //   functions that take `location: CaptureLocation?` gain `context: [MetadataObservation] = []` beside it.
  ```

- [ ] **Step 1: Failing tests.**
  `ContextPolicyTests`:
  - `disabledYieldsNothing`; `freshSnapshotUsed` (takenAt 30 s before start → three entries); `staleSnapshotIgnored` (takenAt 121 s before, `networkAtSave` wifi → only `context.network`); `networkFilledAtSave` (snapshot without network + `networkAtSave` cellular/expensive → `interface == "cellular"`, `expensive == true`); `snapshotNetworkWins` (both present → the snapshot's).
  - `pickCopiesOnlyValidExtras`: fix with `altitude 52`, `verticalAccuracy 3`, `speed -1`, `speedAccuracy -1`, `course -1`, `courseAccuracy -1` → `altitudeMeters == 52`, `verticalAccuracyMeters == 3`, the other four nil; a fix with `verticalAccuracy -1` → `altitudeMeters == nil`.
  - `deviceContextDefaultsOn`: fresh `UserDefaults(suiteName:)` → `deviceContextEnabled == true`; set false → false. `lastSavedRoundTrips`; garbage data under the key → nil.
  `CaptureContextTests` (store opened with hooks backed by a lock-protected box):
  - `enabledAlwaysWritten`: hooks `(deviceContext: false, location: false)` → the committed metadata has exactly one `context.*` entry, `context.enabled` with `groups == []`.
  - `burstWrittenWhenEnabled`: two captures 41.2 s apart with `(true, false)` → the second has `context.burst` with the first's id and `41.2`; the first has none.
  - `burstNotWrittenWhenDisabledButLastSavedStillRecorded`: `(false, false)` for capture A, `(true, false)` for capture B → B has `context.burst` pointing at A.
  - `failedSaveDoesNotRecord`: a draft that throws `CaptureError.emptyCapture` → `recordSaved` not called.
  - `saveWithoutSnapshotStillSaves`: store with hooks, draft with no context observations → saves; `context.enabled` present.
  - `noHooksNoEntries`: store opened without hooks → no `context.*` entries (existing tests unchanged).
  - `existingKeysNotDuplicated`: a draft already carrying `context.enabled` → still exactly one.
  Capture-path tests (extend the existing suites): `RecorderModel`, `ShareSessionModel`, `NoteComposer`, `CameraCapture.stage`, `ShareIntake` each pass a context value through → the committed draft's observations contain it once; comment mode in `NoteComposer`/`RecorderModel` never calls the closure.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "ContextPolicyTests|CaptureContextTests"`. Expected: compile failure.
- [ ] **Step 3: Implement.** In `HippoStore.capture`, before `writer.commit`: when hooks exist, read `enabledGroups()` once, append `ContextObservations.enabled(...)`, and when `deviceContext` is true append `ContextObservations.burst(previous: lastSaved(), capturedAt: d.startedAt)`; skip any key the draft already has. After a successful commit call `recordSaved(LastSaved(captureID: <package id string>, capturedAt: d.startedAt))`. Hook calls are synchronous and cannot throw. Where a model applies `location(startedAt)` to the draft, apply `context(startedAt)` in the same place.
- [ ] **Step 4: Run** the filter and `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat: context policy, settings and store hooks`.

---

### Task 4: App plumbing (platform readers, both targets)

**Files:**
- Create: `App/Shared/ContextReader.swift`, `App/Shared/CaptureContextService.swift`
- Modify: `App/Shared/NetworkStatus.swift`, `App/Shared/LocationService.swift`, `App/Hippo/AppEnvironment.swift` (or wherever `HippoStore.open` is called for the app), `App/HippoShare/ShareViewController.swift`, `App/Hippo/Capture/NoteEditorView.swift`, `App/Hippo/Capture/RecorderView.swift`, `App/Hippo/Capture/CameraCaptureView.swift`, every app site that builds `RecorderModel`, `ShareSessionModel`, `NoteComposer`, `CameraCapture.stage`, `ShareIntake`

**Interfaces:**
- Consumes: Task 3's `context:` parameters, `ContextPolicy.observations`, `CaptureContextHooks`, `AppSettings.deviceContextEnabled`/`lastSaved`.
- Produces:
  ```swift
  @MainActor enum ContextReader {
      static func audioRoute() -> ContextSnapshot.AudioRoute?     // AVAudioSession.sharedInstance().currentRoute; never setActive / setCategory
      static func device() -> ContextSnapshot.Device              // UIDevice, ProcessInfo, key-window traits, Locale
      static func portType(_ p: AVAudioSession.Port) -> String    // §4.1 table; unknown → p.rawValue
  }
  @MainActor final class CaptureContextService {
      static let shared: CaptureContextService
      func begin()                                                // takes and stores one snapshot; no-op when the switch is off
      func observations(startedAt: Date) -> [MetadataObservation] // ContextPolicy.observations(enabled: settings.deviceContextEnabled, snapshot:, captureStartedAt:, networkAtSave: NetworkStatus current)
  }
  // NetworkStatus gains: var current: ContextSnapshot.Network?   — nil until the first NWPath is delivered
  ```

- [ ] **Step 1: `NetworkStatus`.** Keep `isOnline`, the merged `isExpensive` and `onChange` exactly as they behave now. Store the last delivered path's interface (`wifi` if `usesInterfaceType(.wifi)`, else `cellular`, else `wired` for `.wiredEthernet`, else `other`; `none` when status is not `.satisfied`), `isExpensive`, `isConstrained`; expose them as `current`. The Share Extension creates/starts the monitor in `ShareViewController` where it calls `beginSessionFix()`.
- [ ] **Step 2: `ContextReader`.** Port map: `.builtInSpeaker` built_in_speaker, `.builtInReceiver` built_in_receiver, `.builtInMic` built_in_mic, `.headphones` headphones, `.headsetMic` headset_mic, `.bluetoothA2DP` bluetooth_a2dp, `.bluetoothHFP` bluetooth_hfp, `.bluetoothLE` bluetooth_le, `.carAudio` car_audio, `.airPlay` airplay, `.HDMI` hdmi, `.usbAudio` usb_audio, `.lineOut` line_out, `.lineIn` line_in. Battery: enable `isBatteryMonitoringEnabled`, level < 0 → nil, state `.unknown` → nil. Orientation `.unknown` → nil. `uses_24_hour_clock`: the `j` date-format template for `Locale.current` contains no `a`. Locale: `Locale.current.identifier`. Interface style from the key window's traits in the app; from the extension's view controller traits when reachable, else nil.
- [ ] **Step 3: `CaptureContextService`** and call `begin()` at every point that calls `LocationService.shared.beginSessionFix()` for a new capture (`NoteEditorView` on appear when not a comment, `RecorderView`, `CameraCaptureView` on appear, `ShareViewController`), never for a comment. Pass `CaptureContextService.shared.observations(startedAt:)` as the `context` argument at every construction site.
- [ ] **Step 4: `LocationService.fix`** copies `altitude`/`verticalAccuracy`, `speed`/`speedAccuracy`, `course`/`courseAccuracy` from `CLLocation` into `LocationFix`.
- [ ] **Step 5: Hooks.** Both processes open the store with `CaptureContextHooks(enabledGroups: { (settings.deviceContextEnabled, settings.locationEnabled && <location authorized when-in-use or always>) }, lastSaved: { settings.lastSaved }, recordSaved: { settings.lastSaved = $0 })` on the App Group `AppSettings`. Authorization is read from `CLLocationManager().authorizationStatus`; it never prompts.
- [ ] **Step 6: Verify.** `make test`; build the app (command in Global Constraints; it builds HippoShare too); `make uitest`. Expected: all green. In the simulator, make one note and confirm `metadata.json` in the app container has `context.enabled`, `context.device` and `context.network` (print the keys only).
- [ ] **Step 7: Commit** `feat(app): read device context at capture start`.

---

### Task 5: Enrichment infrastructure for the six kinds

**Files:**
- Modify: `HippoKit/Sources/CaptureCore/Enrichment/EnrichmentDocument.swift` (`FacetKind` statics), `CaptureCore/Enrichment/FacetData.swift`, `Enrichment/Enricher.swift` (`EnrichmentError`), `Enrichment/EnrichmentRunner.swift`, `HippoPresentation/Settings/AppSettings.swift`, `schema/enrichment-v1.schema.json`, `HippoKit/Tests/EnrichmentTests/` (runner tests), `HippoKit/Tests/HippoPresentationTests/` (settings tests)

**Interfaces:**
- Produces:
  ```swift
  extension FacetKind {
      static let motionActivity = FacetKind(rawValue: "motion_activity"), weather = FacetKind(rawValue: "weather"),
                 barcodes = FacetKind(rawValue: "barcodes"), language = FacetKind(rawValue: "language"),
                 soundClassification = FacetKind(rawValue: "sound_classification"), screenshot = FacetKind(rawValue: "screenshot")
  }
  // EnrichmentError gains: case notApplicable(code: String)
  //   Runner: marks the task not_applicable exactly as `applies == false` does, writes no facet, counts no attempt,
  //   logs enrich.finished with outcome not_applicable and the code.
  // AppSettings
  public static let enrichmentKindsOffByDefault: Set<FacetKind> = [.motionActivity, .weather]
  //   isEnrichmentEnabled(kind): unset key → !enrichmentKindsOffByDefault.contains(kind)
  // FacetData.swift — Codable, Sendable, Equatable payloads with snake_case keys exactly as §5:
  public struct MotionActivityData { windowStart, windowEnd: Date; atCapture: Sample?; segments: [Sample]
      public struct Sample { startedAt: Date; activities: [String]; confidence: String } }
  public struct WeatherData { observedHour: Date; temperatureCelsius, apparentTemperatureCelsius, relativeHumidityPercent,
      precipitationMillimeters, cloudCoverPercent, windSpeedMetersPerSecond: Double?; weatherCode: Int?; condition: String?;
      isDay: Bool?; source: String; requestedLatitude, requestedLongitude: Double }
  public struct BarcodesData { items: [Item]; public struct Item { attachmentID, symbology, payload: String; url: String? } }
  public struct LanguageData { items: [Item]; public struct Item { source, language: String; confidence: Double } }
  public struct SoundClassificationData { items: [Item]
      public struct Item { attachmentID: String; labels: [Label] }; public struct Label { label: String; confidence: Double } }
  public struct ScreenshotData { items: [Item]; public struct Item { attachmentID, reason: String } }
  ```

- [ ] **Step 1: Failing tests.**
  - Runner: an enricher whose `run` throws `.notApplicable(code: "history_expired")` → task state not_applicable, the device document has no facet of that kind, attempt count unchanged, a later pass does not run it again.
  - Settings: `isEnrichmentEnabled(.motionActivity) == false` and `(.weather) == false` on fresh defaults; the other four new kinds and the six existing kinds `true`; `setEnrichmentEnabled(.weather, true)` → true.
  - Payloads: each struct encodes to the exact key set of its §5 example and decodes it back (use the §5.1 and §5.2 JSON verbatim; `observed_hour` and segment dates through `HippoJSON`).
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter EnrichmentTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Follow the existing payload structs' encoding helpers in `FacetData.swift`/`FacetPayload.swift`.
- [ ] **Step 4: Schema.** `enrichment-v1.schema.json`: `$defs` for the six payloads following the existing per-kind pattern; open string sets stay plain strings.
- [ ] **Step 5: Run** `make test` and `scripts/validate-fixtures.sh`. Expected: PASS.
- [ ] **Step 6: Commit** `feat(enrichment): six context facet kinds, not_applicable from run`.

---
### Task 6: `barcodes` and `screenshot` enrichers

**Files:**
- Create: `HippoKit/Sources/Enrichment/BarcodeEnricher.swift`, `HippoKit/Sources/Enrichment/ScreenshotEnricher.swift`, `HippoKit/Tests/EnrichmentTests/BarcodeEnricherTests.swift`, `HippoKit/Tests/EnrichmentTests/ScreenshotEnricherTests.swift`

**Interfaces:**
- Consumes: `FacetKind.barcodes`, `.screenshot`, `BarcodesData`, `ScreenshotData` (Task 5); the `Enricher` protocol and the injectable-closure pattern of `TextRecognitionEnricher`.
- Produces:
  ```swift
  public struct BarcodeEnricher: Enricher {
      public struct Detected: Sendable, Equatable { public var symbology: String; public var payload: String }
      public typealias Detector = @Sendable (URL) async throws -> [Detected]
      public static let liveDetector: Detector        // VNDetectBarcodesRequest; symbology lowercased, "VNBarcodeSymbology" prefix removed
      public init(detect: @escaping Detector = BarcodeEnricher.liveDetector)
      // kind .barcodes, version 1, usesNetwork false, inputs [], readsAttachmentBytes true, readsCommentAudio false
  }
  public struct ScreenshotEnricher: Enricher {
      public struct ImageFacts: Sendable, Equatable { public var pixelWidth, pixelHeight: Int?; public var exifUserComment, cameraMake, cameraModel: String? }
      public typealias Inspector = @Sendable (URL) -> ImageFacts?
      public static let liveInspector: Inspector      // ImageIO CGImageSource properties; never decodes pixels
      public init(screenPixelSize: (width: Int, height: Int)?, inspect: @escaping Inspector = ScreenshotEnricher.liveInspector)
      // kind .screenshot, version 1, provenance "heuristic", readsAttachmentBytes true
  }
  ```
  Both apply to captures with at least one image attachment (same test `TextRecognitionEnricher` uses).

- [ ] **Step 1: Failing tests.**
  `BarcodeEnricherTests` (fake detector unless noted):
  - `qrUrlRecorded`: payload `https://example.com/a` on attachment A → `ok`, one item `{attachment_id: A, symbology: "qr", payload, url: "https://example.com/a"}`, provenance `vision`.
  - `nonUrlPayloadHasNoUrl`: `ean13` / `4006381333931` → no `url` key; `ftp://x` and `HTTPS://Example.com` → the first has no `url`, the second has one.
  - `capsApplied`: a 5,000-character payload → 2,048; 30 detections on one attachment → 20; two attachments with 20 each → 40 items.
  - `noBarcodesIsEmpty` → status `empty`; `nonImageAttachmentsSkipped`; a detector that throws for one of two images → the other's items are still written (`ok`); throwing for all → `EnrichmentError.transient`.
  - `liveDetectorReadsGeneratedQR`: render a QR for `https://example.com/hippo` with `CIFilter` `CIQRCodeGenerator` scaled ×10 to a PNG in a temp dir → `liveDetector` returns one `qr` with that payload.
  `ScreenshotEnricherTests`:
  - `exifCommentMatches`: facts `exifUserComment: "Screenshot"` → item reason `exif_user_comment`.
  - `screenSizeMatchesEitherOrientation`: screen 1206×2622; facts 1206×2622 and 2622×1206 without make/model → `screen_size_match`; with `cameraMake: "Apple"` → no item; `screenPixelSize: nil` → no size match.
  - `exifWins` when both hold; `noMatchIsEmpty`; inspector returning nil → skipped, not failed.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "BarcodeEnricherTests|ScreenshotEnricherTests"`. Expected: compile failure.
- [ ] **Step 3: Implement.** URL rule: `URL(string:)` parses and scheme lowercased is `http` or `https`. Neither enricher fetches anything or touches `urls`.
- [ ] **Step 4: Run** the filter and `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(enrichment): barcodes and screenshot facets`.

---

### Task 7: `language` and `sound_classification` enrichers

**Files:**
- Create: `HippoKit/Sources/Enrichment/LanguageEnricher.swift`, `HippoKit/Sources/Enrichment/SoundClassificationEnricher.swift`, `HippoKit/Tests/EnrichmentTests/LanguageEnricherTests.swift`, `HippoKit/Tests/EnrichmentTests/SoundClassificationEnricherTests.swift`

**Interfaces:**
- Consumes: `FacetKind.language`, `.soundClassification`, `LanguageData`, `SoundClassificationData` (Task 5); `EnricherInput.noteBody`, `.comments`; how `TranscriptEnricher` enumerates audio attachments and audio comments.
- Produces:
  ```swift
  public struct LanguageEnricher: Enricher {
      public typealias Recognizer = @Sendable (String) -> (language: String, confidence: Double)?
      public static let liveRecognizer: Recognizer     // NLLanguageRecognizer dominant language + its hypothesis probability
      public static let minimumLength = 20
      public init(recognize: @escaping Recognizer = LanguageEnricher.liveRecognizer)
  }
  public struct SoundClassificationEnricher: Enricher {
      public struct Label: Sendable, Equatable { public var label: String; public var confidence: Double }
      public typealias Classifier = @Sendable (URL) async throws -> [Label]   // mean confidence per label over the file
      public static let liveClassifier: Classifier     // SNAudioFileAnalyzer + SNClassifySoundRequest(classifierIdentifier: .version1)
      public static let minimumConfidence = 0.3, maxLabels = 8
      public init(classify: @escaping Classifier = SoundClassificationEnricher.liveClassifier)
      // readsAttachmentBytes true, readsCommentAudio true; applies(to:comments:) true with an audio attachment or an audio comment
  }
  ```

- [ ] **Step 1: Failing tests.**
  `LanguageEnricherTests`:
  - `sourcesInOrder`: metadata with `user_note`, `shared_text` and a `noteBody`, each ≥ 20 characters, fake recognizer → items with `source` `user_note`, `shared_text`, `note_body` in that order.
  - `shortTextSkipped`: 19 characters (after trimming whitespace) → skipped; 20 → kept. All skipped → `applies` is false (not_applicable).
  - `unrecognizedIsEmpty`: recognizer returns nil for every source → `empty`.
  - `liveRecognizerKnowsSpanishAndEnglish`: "Mañana tengo que comprar pan y leche en el mercado." → `es`; an English sentence → `en`; confidence within 0...1.
  `SoundClassificationEnricherTests`:
  - `filtersSortsAndCaps`: fake returns 12 labels with confidences 0.95 … 0.05 → kept are those ≥ 0.3, strongest first, at most 8.
  - `commentAudioUsesCommentID`: an audio comment → item `attachment_id == comment_id`; a text comment is ignored.
  - `nothingAboveThresholdIsEmpty`; one file throwing while another succeeds → `ok` with the one item; all throwing → `transient`.
  - `liveClassifierAcceptsRecordedM4A`: a 2 s file from the test support audio maker (the helper the fixtures generator uses) → `liveClassifier` returns without throwing (labels may be empty). This is spec §11 item 4; if it throws on the simulator runtime only, mark the test with a `.disabled` trait naming the reason and report it.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "LanguageEnricherTests|SoundClassificationEnricherTests"`. Expected: compile failure.
- [ ] **Step 3: Implement.** Mean confidence = sum of a label's confidence over all result windows ÷ number of windows. Language tags are `NLLanguage.rawValue`.
- [ ] **Step 4: Run** the filter and `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(enrichment): language and sound classification facets`.

---

### Task 8: `weather` enricher

**Files:**
- Create: `HippoKit/Sources/Enrichment/WeatherEnricher.swift`, `HippoKit/Sources/Enrichment/OpenMeteo.swift`, `HippoKit/Sources/Enrichment/RequestPacer.swift`, `HippoKit/Tests/EnrichmentTests/WeatherEnricherTests.swift`

**Interfaces:**
- Consumes: `FacetKind.weather`, `WeatherData` (Task 5); `HTTPFetching.get(_:timeout:maxBytes:)`.
- Produces:
  ```swift
  public enum OpenMeteo {
      public static let forecastWindow: TimeInterval = 60 * 86_400
      /// Forecast API when now − capturedAt ≤ forecastWindow, archive API otherwise. Coordinates rounded to 2 decimals.
      public static func request(latitude: Double, longitude: Double, capturedAt: Date, now: Date) -> URL
      public static func archiveRequest(latitude: Double, longitude: Double, capturedAt: Date) -> URL
      /// nil when the hour is missing from `hourly.time` or every variable is null for it.
      public static func parse(_ body: Data, hour: Date, latitude: Double, longitude: Double) throws -> WeatherData?
      public static func condition(forCode code: Int) -> String?
  }
  public actor RequestPacer {
      public init(minimumInterval: Duration = .seconds(1), sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                  now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now })
      public func wait() async            // returns when ≥ minimumInterval has passed since the previous return
  }
  public struct WeatherEnricher: Enricher {
      public init(http: any HTTPFetching, pacer: RequestPacer = RequestPacer(), now: @escaping @Sendable () -> Date = Date.init)
      // kind .weather, version 1, usesNetwork true, provenance "open_meteo"; applies only when the capture has a location
  }
  ```
  URLs (verified live 2026-11-10):
  - Forecast: `https://api.open-meteo.com/v1/forecast?latitude=47.61&longitude=-122.33&hourly=temperature_2m,apparent_temperature,relative_humidity_2m,precipitation,cloud_cover,wind_speed_10m,weather_code,is_day&wind_speed_unit=ms&timezone=GMT&start_hour=2026-11-08T14:00&end_hour=2026-11-08T14:00`
  - Archive: `https://archive-api.open-meteo.com/v1/archive?` with the same `latitude`, `longitude`, `hourly`, `wind_speed_unit`, `timezone` and `start_date=2026-01-03&end_date=2026-01-03` (returns 24 hours; pick the capture's hour).
  - `hourly.time` entries look like `"2026-11-08T14:00"` (GMT). The forecast API rejects hours older than about 92 days with HTTP 400.
  Condition map: 0, 1 `clear`; 2 `partly_cloudy`; 3 `cloudy`; 45, 48 `fog`; 51–55 `drizzle`; 56, 57, 66, 67 `freezing_rain`; 61–65 `rain`; 71–77, 85, 86 `snow`; 80–82 `showers`; 95–99 `thunderstorm`; anything else nil (field omitted).

- [ ] **Step 1: Failing tests** (fake `HTTPFetching` recording URLs and returning canned bodies; pacer with a no-op sleep):
  - `forecastURLForRecentCapture`: capture at 2026-11-08T14:37:12Z, lat 47.61234, lon −122.33456, now two days later → the exact forecast URL above. `archiveURLForOldCapture`: now 61 days later → archive host, `start_date=end_date=2026-11-08`.
  - `parsesEveryField`: canned forecast body for that hour → payload equal to §5.2's shape: `observed_hour == 2026-11-08T14:00:00Z`, `source == "open-meteo.com"`, `requested_latitude == 47.61`, `requested_longitude == -122.33`, `is_day` Bool from 0/1, `condition == "rain"` for code 61, provenance `open_meteo`.
  - `archivePicksTheHour`: a 24-hour body → values of index 14.
  - `nullVariablesOmitted`: `temperature_2m: [null]` → no `temperature_celsius` key, others present. `allNullIsEmpty` and `hourMissingIsEmpty` → status `empty`.
  - `conditionTable`: every code in the map above, and 4 → nil.
  - `noLocationNotApplicable`: `applies(to:)` false.
  - `failuresClassified`: fetch throws / HTTP 500 / 429 → `EnrichmentError.transient`; forecast HTTP 400 → one retry against `archiveRequest`, and if that also fails with 4xx → `.permanent(code: "weather_http_400")`; malformed JSON → `.permanent(code: "weather_bad_response")`.
  - `pacerSpacesRequests`: `RequestPacer` with an injected clock and a recording sleep → the second `wait()` within 0.2 s of the first sleeps about 0.8 s; a call 2 s later does not sleep. `enricherWaitsBeforeEachRequest`: two runs → pacer consulted twice.
  - `coordinatesNeverMoreThanTwoDecimals`: no recorded URL contains `47.612` or `122.334`.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter WeatherEnricherTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Timeout 15 s, `maxBytes` 64 KiB. The hour is `capturedAt` floored to the hour in GMT. One `RequestPacer` instance lives as long as the enricher.
- [ ] **Step 4: Run** the filter and `make test`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(enrichment): weather facet from Open-Meteo`.

---

### Task 9: `motion_activity` enricher and wiring all six kinds

**Files:**
- Create: `HippoKit/Sources/Enrichment/MotionActivityEnricher.swift`, `HippoKit/Tests/EnrichmentTests/MotionActivityEnricherTests.swift`, `App/Hippo/Enrichment/CoreMotionHistory.swift`
- Modify: the file declaring `EnrichmentScheduling` (`kinds`, `runner(for:)`), its tests, `project.yml` (`targets.Hippo.info.properties`), the app site that builds the runner's enrichers

**Interfaces:**
- Consumes: `FacetKind.motionActivity`, `MotionActivityData`, `EnrichmentError.notApplicable` (Task 5); the enrichers of Tasks 6–8; `AppSettings.isEnrichmentEnabled`.
- Produces:
  ```swift
  public struct MotionSample: Sendable, Equatable { public var startedAt: Date; public var activities: [String]; public var confidence: String }
  public enum MotionHistoryError: Error, Sendable { case unauthorized, unavailable }
  public protocol MotionHistoryProviding: Sendable { func samples(from: Date, to: Date) async throws -> [MotionSample] }
  public struct MotionActivityEnricher: Enricher {
      public static let halfWindow: TimeInterval = 600, historyLimit: TimeInterval = 7 * 86_400, maxSegments = 60
      public init(history: any MotionHistoryProviding, now: @escaping @Sendable () -> Date = Date.init)
      // kind .motionActivity, version 1, usesNetwork false, provenance "core_motion"; applies to every capture
  }
  // App: final class CoreMotionHistory: MotionHistoryProviding (CMMotionActivityManager.queryActivityStarting)
  //      static var authorization: CMAuthorizationStatus; static func requestAccess() async -> Bool  (used by Task 10)
  // EnrichmentScheduling.kinds gains the six kinds after the existing six, in the order
  //   barcodes, screenshot, language, soundClassification, weather, motionActivity
  ```

- [ ] **Step 1: Failing tests** (fake history; `capturedAt = T`):
  - `recentCaptureIsDeferred`: now = T + 120 → throws `.deferred(code: "motion_window_open", retryAfter: T + 600)`; the history is not queried.
  - `expiredHistoryIsNotApplicable`: now = T + 7 days + 1 s → throws `.notApplicable(code: "motion_history_expired")`; not queried.
  - `windowAndAtCapture`: now = T + 700; samples at T−500 walking/medium, T−100 automotive+stationary/high, T+200 automotive/high → queried with `(T−600, T+600)`; `window_start`/`window_end` equal those; `at_capture` is the T−100 sample with `activities == ["stationary", "automotive"]`; three segments in time order; status `ok`.
  - `mergesIdenticalNeighbours`: five consecutive walking/medium samples → one segment starting at the first; a confidence change splits.
  - `capsSegments`: 100 alternating samples → 60 segments (the first 60), `at_capture` still the true last sample at or before T.
  - `noSampleBeforeCaptureOmitsAtCapture`; `noSamplesIsEmpty` → status `empty`.
  - `activityOrderIsFixed`: flags given in any order encode as `stationary, walking, running, cycling, automotive, unknown`.
  - `unauthorizedIsDeferred`: history throws `.unauthorized` → `.deferred(code: "motion_unauthorized", retryAfter: now + 86_400)`; `.unavailable` → `.notApplicable(code: "motion_unavailable")`; any other error → `.transient`.
  - Scheduling: `EnrichmentScheduling.kinds.count == 12`; with fresh settings the scheduled set excludes `motion_activity` and `weather` and includes the other four; enabling each adds it.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter MotionActivityEnricherTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the enricher, then `CoreMotionHistory`: map `CMMotionActivity` flags in the fixed order, confidence `.low/.medium/.high` → `low/medium/high`; `isActivityAvailable() == false` → `.unavailable`; authorization not `.authorized` → `.unauthorized`; the query's `CMErrorMotionActivityNotAuthorized` → `.unauthorized`. It never triggers the permission prompt on its own: it only queries when already authorized.
- [ ] **Step 4: Wire.** `runner(for:)` builds `BarcodeEnricher()`, `ScreenshotEnricher(screenPixelSize: <UIScreen nativeBounds in pixels>)`, `LanguageEnricher()`, `SoundClassificationEnricher()`, `WeatherEnricher(http: <the runner's existing HTTPFetching>)`, `MotionActivityEnricher(history: CoreMotionHistory())`. `project.yml`: `NSMotionUsageDescription` with the copy in Global Constraints, next to the other usage strings (main app only; HippoShare gets nothing).
- [ ] **Step 5: Verify.** `make test`; app build. Expected: green; `grep -c NSMotionUsageDescription` in the generated app Info.plist source is 1 and absent from the HippoShare one.
- [ ] **Step 6: Commit** `feat(enrichment): motion activity facet; schedule the six context kinds`.

---
### Task 10: Settings "Context" section and four enrichment switches

**Files:**
- Modify: `HippoKit/Sources/HippoPresentation/Settings/SettingsModel.swift`, `HippoKit/Tests/HippoPresentationTests/SettingsModelTests.swift` (the existing settings suite), `App/Hippo/Settings/SettingsView.swift`, the app site that builds `SettingsModel`, `docs/log-format.md` (`settings.changed` kinds)

**Interfaces:**
- Consumes: `AppSettings.deviceContextEnabled`, `isEnrichmentEnabled`/`setEnrichmentEnabled`, `FacetKind.motionActivity`/`.weather`, `CoreMotionHistory.authorization`/`requestAccess()` (Task 9).
- Produces (on `SettingsModel`):
  ```swift
  public private(set) var deviceContextEnabled: Bool
  public private(set) var motionEnabled: Bool
  public private(set) var motionDenied: Bool             // last request was refused, or status is denied/restricted
  public private(set) var weatherEnabled: Bool
  public func setDeviceContextEnabled(_ on: Bool)
  public func setMotionEnabled(_ on: Bool) async         // on: await requestMotionPermission(); refused → stays off, motionDenied = true
  public func setWeatherEnabled(_ on: Bool)
  public static let deviceContextFooter, weatherFooter: String        // verbatim from Global Constraints
  public static let motionFooter = "Records whether you were still, walking, running, cycling or in a vehicle around each capture. Needs Motion & Fitness access. iOS keeps about seven days of history, so open Hippo within a week of a capture."
  public static let motionDeniedFooter = "Motion & Fitness access is off for Hippo. Turn it on in iOS Settings."
  // init gains, after requestLocationPermission:
  //   requestMotionPermission: @escaping () async -> Bool = { false }, motionDenied: @escaping () -> Bool = { false }
  // enrichmentSwitches: the six existing, then
  //   (.barcodes, "Barcodes and QR codes"), (.language, "Language"), (.soundClassification, "Sounds in recordings"), (.screenshot, "Screenshots")
  ```

- [ ] **Step 1: Failing tests.**
  - `contextDefaults`: fresh settings → `deviceContextEnabled == true`, `motionEnabled == false`, `weatherEnabled == false`.
  - `deviceContextToggleWritesSharedDefaults`: `setDeviceContextEnabled(false)` → `AppSettings.deviceContextEnabled == false`; one `settings.changed` log line with `kind == "device_context"`, `on == false`.
  - `motionGrantedTurnsOn`: permission closure returns true → `motionEnabled`, `isEnrichmentEnabled(.motionActivity)`, `onEnrichmentEnabled` called once (the hook that kicks a backfill pass, as `setEnrichment` does today).
  - `motionRefusedStaysOff`: closure returns false → `motionEnabled == false`, `motionDenied == true`, `onEnrichmentEnabled` not called. `motionOffNeverAsks`: `setMotionEnabled(false)` does not call the closure.
  - `weatherToggle`: on → `isEnrichmentEnabled(.weather)` and `onEnrichmentEnabled` called; off → false.
  - `enrichmentSwitchesAreTen`: titles in order end with the four new ones; `motion_activity` and `weather` are not in that list.
  - `footersVerbatim`: `deviceContextFooter` and `weatherFooter` equal the Global Constraints strings.
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter SettingsModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the model. `settings.changed` kinds: `device_context`, `motion_activity`, `weather` (the last two through the same path `setEnrichment` uses).
- [ ] **Step 4: `SettingsView`.** A "Context" section between the location and camera sections: three `Toggle`s, each in its own `Section` footer arrangement so every footer sits under its switch; the motion footer shows `motionDeniedFooter` plus the existing "Open Settings" affordance used by location when `motionDenied`. Accessibility identifiers `device-context-switch`, `motion-switch`, `weather-switch`. The Enrichment section renders `enrichmentSwitches` as it does today (ten rows). The app passes `requestMotionPermission: { await CoreMotionHistory.requestAccess() }` and `motionDenied: { CoreMotionHistory.authorization == .denied || == .restricted }`.
- [ ] **Step 5: `docs/log-format.md`**: add the three kinds to the `settings.changed` row.
- [ ] **Step 6: Verify.** `make test`; app build. Expected: green.
- [ ] **Step 7: Commit** `feat(settings): Context section; four more enrichment switches`.

---

### Task 11: Detail "Context" section

**Files:**
- Create: `HippoKit/Sources/HippoPresentation/Detail/ContextRows.swift`, `HippoKit/Tests/HippoPresentationTests/ContextRowsTests.swift`
- Modify: `HippoPresentation/Detail/CaptureDetail.swift` (`context: [DetailRow]`, default `[]`), `HippoPresentation/Detail/CaptureDetailModel.swift` (fills it where it builds `captured`), `App/Hippo/Detail/` view that renders sections

**Interfaces:**
- Consumes: `ContextKey`, the six payload structs (Task 5), `CaptureLocation` extras, `DetailRow`, `Layer`.
- Produces:
  ```swift
  public enum ContextRows {
      /// Rows in the order below; a signal that is absent, empty or undecodable produces no row. Never throws.
      public static func rows(metadata: CaptureMetadata, device: EnrichmentDocument?, locale: Locale) -> [DetailRow]
  }
  ```
  Rows (label → value; layer `.bronze` for `metadata.json` facts, `.silver` for facets):
  1. `Audio` → output port names joined with ", " (a port without a name shows its type with underscores as spaces); inputs are not shown. "CarPlay".
  2. `Battery` → "62%" (unplugged), "62%, charging", "100%, full"; level missing → the state alone; both missing → no row.
  3. `Network` → "Wi-Fi", "Cellular", "Wired", "Other", "Offline"; plus ", Low Data Mode" when constrained.
  4. `Previous capture` → "41 s earlier" (< 90 s), "5 min earlier" (< 90 min), "3 h earlier" (< 48 h), else "4 d earlier".
  5. `Altitude` → "52 m"; `Speed` → "13.4 m/s" (only when present).
  6. `Motion` → "Driving, high confidence" from `at_capture`, else from the first segment. Names: stationary Still, walking Walking, running Running, cycling Cycling, automotive Driving, unknown Unknown; several joined with " + " in the fixed order.
  7. `Weather` → "14°C, rain, night": rounded temperature, `condition` with underscores as spaces, "day"/"night" from `is_day`; missing parts dropped.
  8. `Sounds` → up to three distinct labels across items, strongest first, underscores as spaces: "speech, traffic noise".
  9. `QR code` (symbology `qr`) or `Barcode` → the `url` without scheme, else the payload; truncated to 40 characters with "…"; at most three rows.
  10. `Language` → the language's name in `locale` ("Spanish"), one row per distinct language.
  11. `Image` → "Looks like a screenshot" when the screenshot facet has an item.

- [ ] **Step 1: Failing tests** in `ContextRowsTests.swift` (en_US): one test per row above with the quoted outputs, plus `nothingRecordedIsEmpty` (a 1.0 metadata, nil document → `[]`), `contextEnabledAloneShowsNothing` (only `context.enabled` → `[]`), `malformedValuesAreSkipped` (`context.device` whose value is a string, a `weather` facet with status `failed`, a `barcodes` facet with status `empty` → no rows, no crash), `layers` (Audio is `.bronze`, Motion is `.silver`).
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter ContextRowsTests`. Expected: compile failure.
- [ ] **Step 3: Implement**; `CaptureDetailModel` passes the same device document it already loads for the other silver rows.
- [ ] **Step 4: App.** Render a "Context" section after the existing "Captured" rows using the same row view and layer stripe; hidden when `context` is empty. No timeline change.
- [ ] **Step 5: Verify.** `make test`; app build; `make uitest`. Expected: green.
- [ ] **Step 6: Commit** `feat(detail): Context section`.

---
### Task 12: Documents and fixtures

**Files:**
- Create: `docs/context-signals.md`, `docs/folder-readme.md`
- Modify: `docs/package-format.md`, `docs/enrichment-format.md`, `README.md`, `docs/acceptance.md`, `docs/roadmap.md`, `fixtures/README.md`, `HippoKit/Sources/hippo-fixtures/main.swift`, `HippoKit/Tests/CaptureCoreTests/` fixture tests, new files under `fixtures/packages/`

**Interfaces:**
- Consumes: everything Tasks 1–11 named (keys, fields, facet kinds, copy). The documents must use those names exactly.
- Produces: `docs/folder-readme.md` whose first line is the marker in Global Constraints (Task 13 bundles and tests it); the four document file names Task 13 uploads.

- [ ] **Step 1: Fixtures.** Add a generator mode `context <fixtures-root>` to `hippo-fixtures` that writes only: package 7 (`captureID(7)`, `started(7)`, method `share_extension`) with a `user_note` of at least 20 characters, one PNG attachment containing a QR code for `https://example.com/hippo`, one 1 s audio attachment, a `capture_location` carrying all six extras, and the five `context.*` observations built with `ContextObservations` from a fixed `ContextSnapshot` (`car_audio`/"CarPlay" output, every device field, `wifi`) with `previous_capture_id = captureID(6)`; and `enrichments/device/…/enrichment.json` for capture 7 holding all six facets with hand-built payloads (§5.1 and §5.2 examples for motion and weather). All IDs and dates fixed; output byte-stable across runs. The default mode and packages 1–6 are not touched: they are the frozen 1.0 files. Run the new mode and commit its output.
- [ ] **Step 2: Fixture tests.**
  - `legacyFixturesHaveNoMinor`: the raw bytes of `metadata.json` and `complete.json` of packages 1–6, the comment fixtures of package 4 and capture 2's `enrichment.json` do not contain `schema_minor`, and all still decode and validate (`PackageValidator` `.complete`).
  - `contextFixtureCarriesEverySignal`: package 7 decodes with `schemaMinor == 1`; its observation keys include all five `ContextKey`s; the six location extras are non-nil; its device document has `schemaMinor == 1` and facets of all six new kinds, each decodable into its payload struct.
- [ ] **Step 3: Run** `make test` and `scripts/validate-fixtures.sh`; `git status --short fixtures/packages/captures/2026/11/07` shows only package 7 as new. Expected: PASS.
- [ ] **Step 4: `docs/package-format.md`.** Title "version 1.1". New "Versioning" section with the rules of §7 (major, minor, missing = 0, accept any minor, reject unknown major, no patch, not a string). The six `capture_location` fields with units (§4.5 table). A "Context observations" section: the five keys with their value tables from §4.1–§4.4 and §4.6, the caps, and "absent means not read that time; see `context.enabled`". "Format history": `1.0` (2026-11-07 → 2026-11-10: packages, enrichment, comments, the `camera` method) and `1.1` (2026-11-10: `schema_minor`, the `context.*` observations, location extras, six facet kinds). Reader algorithm: one line on ignoring unknown keys and minors.
- [ ] **Step 5: `docs/enrichment-format.md`.** Title "version 1.1"; `schema_minor`; one subsection per new facet kind with the payload table, units, statuses (`ok`, `empty`, when no facet is written) and provenance from §5; the WMO-to-`condition` table from Task 8; "Weather data by Open-Meteo.com (CC BY 4.0)".
- [ ] **Step 6: `docs/context-signals.md`.** One table, one row per signal (five observations, six location extras as one row each, six facets): Signal, What it is, File, Key or facet kind, Value and units, Provenance, Settings switch, Since (`1.1`), What absence means. Then "Answering recall questions": three worked examples as hints to a reader, not rules the phone applies ("in a car": `motion_activity` automotive, `context.audio_route` output `car_audio`, `speed_meters_per_second` above about 3; "on headphones": outputs `headphones` / `bluetooth_a2dp`; "several captures in a row": `context.burst.seconds_since_previous` small), and how to tell "recorded and negative" from "not recorded" (`context.enabled.groups`, `schema_minor`, facet absence).
- [ ] **Step 7: `docs/folder-readme.md`.** Line 1 is the marker, exactly. Then: what Hippo is in two sentences; the layout (`captures/`, `enrichments/device/`, `enrichments/server/`, `logs/`, `format/`); the order to read things (`format/package-format.md`, `format/enrichment-format.md`, `format/context-signals.md`, `format/schema/`); "Format version 1.1"; a writer may write only under `enrichments/server/`, everything else is read-only. No relative links that only work in the repo.
- [ ] **Step 8: README, acceptance, roadmap.** README: "Format and versioning" section pointing at the four documents; the Context settings and the Detail section described; "Weather data by Open-Meteo.com"; Known limits gain "a share-sheet capture gets motion only if Hippo is opened within seven days". `docs/acceptance.md`: rows X1–X12, all "not run", one per item of §10's device list in that order (share sheet; each in-app path; headphones; CarPlay or car Bluetooth; switch off leaves only `context.enabled`; motion permission flow and a walking capture; weather on a located capture; a QR code picture; a screenshot; a voice note with music; `README.md` and `format/` in Dropbox; an old capture still opens). `docs/roadmap.md`: mark capture context "Done (2026-11-10)" with the design link, keep the WeatherKit swap and the offline indexer as later items.
- [ ] **Step 9: Commit** `docs: format 1.1, signal registry, folder README; context fixtures`.

---

### Task 13: The self-describing folder

**Files:**
- Create: `HippoKit/Sources/SyncEngine/FormatBundle.swift`, `HippoKit/Sources/SyncEngine/FormatUploader.swift`, `HippoKit/Tests/SyncEngineTests/FormatUploaderTests.swift`
- Modify: `SyncEngine/StorageAdapter.swift` (`ReplacePolicy`), `SyncEngine/FilesystemAdapter.swift:146`, the Dropbox adapter's `replaceFile` guard (`DropboxAdapter.swift:207`), `HippoKit/Tests/AdapterContractTests/`, `HippoKit/Tests/DropboxAdapterTests/`, `SyncEngine/HippoStore.swift`, `HippoPresentation/Settings/SyncCoordinator.swift`, `LocalRepository/Log/LogEvent.swift`, `project.yml`, the app site that builds `SyncCoordinator`, `docs/log-format.md`

**Interfaces:**
- Consumes: `docs/folder-readme.md`, `docs/package-format.md`, `docs/enrichment-format.md`, `docs/context-signals.md`, `schema/*.schema.json` (Task 12); `StorageAdapter.inspectFile`, `downloadFile(relativePath:to:maxBytes:…)`, `replaceFile`, `ensureContainer`; `LogUploader` as the model for destinations, `adapterFor` and never-throwing passes.
- Produces:
  ```swift
  public enum ReplacePolicy {
      /// true for the prefixes "enrichments/", "logs/", "format/" and the exact path "README.md".
      public static func allows(_ relativePath: String) -> Bool
  }
  public struct FormatBundle: Sendable, Equatable {
      public struct File: Sendable, Equatable { public var relativePath: String; public var localURL: URL }
      public static let readmeMarker = "<!-- Hippo folder README. Written by the Hippo app and replaced when the app updates. -->"
      public static let readmeReadCap: Int64 = 64 * 1024
      public var formatFiles: [File]   // format/README.md, format/context-signals.md, format/enrichment-format.md, format/package-format.md, format/schema/<name>, sorted by path
      public var readme: File          // relativePath "README.md", the same local file as format/README.md
      public var digest: String        // sha256 hex over each (relativePath, file sha256) in order, README.md last
      /// `docsDirectory` holds the four .md files; `schemaDirectory` holds *.schema.json. Throws when a document is
      /// missing, no schema is found, or folder-readme.md does not start with `readmeMarker`.
      public static func load(docsDirectory: URL, schemaDirectory: URL) throws -> FormatBundle
  }
  public enum FormatUploadResult: Sendable, Equatable { case noBundle, noDestination, unchanged, uploaded(files: Int, readmeSkipped: Bool), failed(code: String) }
  public final class FormatUploader: Sendable {
      // built by HippoStore.makeFormatUploader(bundle: FormatBundle?, adapterFor: @escaping @Sendable (Destination) throws -> any StorageAdapter)
      public func upload() async -> FormatUploadResult      // never throws
  }
  // LogEvent: formatUploaded = "format.uploaded" (count), formatUploadFailed = "format.upload_failed" (code),
  //           formatReadmeSkipped = "format.readme_skipped" (code "readme_foreign")
  // SyncCoordinator.init gains formatUploader: FormatUploader? = nil
  ```
  State: `format-upload-state.json` in the store root, `{ "<destination id>": { "digest": "<hex>" } }`, written atomically.

- [ ] **Step 1: Failing tests.**
  Adapters (contract suite, so it runs for the filesystem adapter; the same assertions in the Dropbox suite against its fake transport):
  - `replaceAllowedPaths`: `replaceFile` succeeds for `README.md`, `format/README.md`, `format/schema/a.schema.json`, and still for `enrichments/…` and `logs/…`; throws `StorageError.permanent(code: "replace_not_allowed")` for `README.md.bak`, `readme.md`, `formatting/a.md`, `format`, `captures/2026/11/07/x/metadata.json`, `notes/README.md`.
  `FormatUploaderTests` (filesystem adapter on a temp destination; bundle loaded from the repo's real `docs/` and `schema/` through `#filePath`):
  - `repoBundleLoads`: `load` succeeds; `formatFiles` are exactly the four documents plus the four schemas under `format/schema/`; the readme's first line equals `readmeMarker`.
  - `firstPassUploadsEverything`: `.uploaded(files: 9, readmeSkipped: false)`; every path exists with the local bytes; `README.md` is the last write (recording adapter wrapper); one `format.uploaded` log line.
  - `secondPassIsUnchanged`: no adapter call at all on the second `upload()`.
  - `changedBundleReuploads`: a bundle from a temp copy with one document edited → uploaded again; state holds the new digest.
  - `hippoReadmeIsReplaced`: destination `README.md` starting with the marker but different bytes → replaced.
  - `foreignReadmeIsLeftAlone`: destination `README.md` = "my notes" → bytes untouched, `format/README.md` written, result `readmeSkipped: true`, one `format.readme_skipped` line with code `readme_foreign`; the next `upload()` is `.unchanged` (no retry until the bundle changes).
  - `oversizedReadmeIsForeign`: a 70 KiB `README.md` that starts with the marker → treated as foreign (the 64 KiB cap).
  - `failureIsRetried`: adapter wrapper failing the third write → `.failed(code:)`, one `format.upload_failed` line, state not advanced; the next pass with a healthy adapter uploads.
  - `noDestinationAndNoBundle`: `.noDestination` / `.noBundle`, nothing logged.
  - `formatFilesInvisibleToReaders`: after an upload into a destination that also holds one synced capture, run the gold puller, the remote change detector, the remote review listing and Download's listing → no error, no change or new capture reported, counts as before.
  - `deleteEverywhereLeavesFormatFiles`: after "Delete everywhere" on that capture, `README.md` and `format/` are still there.
  - Coordinator: `runPass()` calls the format uploader before the worker rounds; a `.failed` result does not stop the pass (the capture still uploads).
- [ ] **Step 2: Run** `swift test --package-path HippoKit --filter "FormatUploaderTests|AdapterContractTests|DropboxAdapterTests"`. Expected: FAIL.
- [ ] **Step 3: Implement.** Both adapters call `ReplacePolicy.allows`. Uploader per live destination (the set `LogUploader` uses): state digest equal → skip. Else `ensureContainer` for `format` and `format/schema`, `replaceFile` each `formatFiles` entry in order, then the root README: `inspectFile("README.md")` nil → `replaceFile`; otherwise `downloadFile` to a temp file with `maxBytes: readmeReadCap` and replace only when its first line is the marker; a size-cap error or any other first line means foreign. Record the digest after a pass that finished (foreign README included). Any thrown error: log, return `.failed`, leave state. Logs carry counts and codes only.
- [ ] **Step 4: Bundle and wire.** `project.yml`, Hippo target only: add the four `docs/*.md` files as resources and `schema` as a folder reference (`type: folder`). The app builds `FormatBundle.load(docsDirectory: Bundle.main.resourceURL!, schemaDirectory: …appending "schema")` with `try?` (a missing bundle is `.noBundle`, never a crash) and passes `store.makeFormatUploader(...)` to `SyncCoordinator`. Confirm that connecting a destination triggers a sync pass; if it does not, call `formatUploader.upload()` after validation succeeds.
- [ ] **Step 5: `docs/log-format.md`**: the three `format.*` events with their fields.
- [ ] **Step 6: Verify.** `make test`; app build; confirm the built app contains `folder-readme.md` and `schema/enrichment-v1.schema.json` (`find` in the build products). Expected: green.
- [ ] **Step 7: Commit** `feat(sync): upload README and format/ so the folder describes itself`.

# Hippo context signals, format 1.1

The registry of every signal Hippo records about the circumstances of a capture. Each is a plain fact with a stable key, a typed value with units, and a provenance. Hippo never records a conclusion such as "in a car": it records the facts that suggest one, and a reader decides.

Field-level detail is in `package-format.md` (capture-time signals, in `metadata.json`) and `enrichment-format.md` (looked-up signals, in the device `enrichment.json`). Machine-readable definitions are in `schema/`. Read those two documents for value shapes; this one says what exists, where, and what a missing value means.

## Where signals live

| File | Written | By |
|---|---|---|
| `captures/YYYY/MM/DD/<capture-id>/metadata.json` | When the capture is saved. Never rewritten. | The app and the Share Extension. |
| `enrichments/device/YYYY/MM/DD/<capture-id>/enrichment.json` | Later, and replaced when it is redone. | The main app only. |

Read both files for a capture. A signal that needs a permission or the network is never collected by the Share Extension.

## Signals

"Since" is the format minor that introduced the signal. Every signal here is since `1.1`.

| Signal | What it is | File | Key or facet kind | Value and units | Provenance | Settings switch | Since | What absence means |
|---|---|---|---|---|---|---|---|---|
| Audio route | Where sound was going and coming from when the capture began (speaker, headphones, car) | `metadata.json` | `context.audio_route` | `outputs`, `inputs`: up to 8 ports each, `{port_type, port_name?}` | `av_audio_session` | Save device context with captures (on) | 1.1 | The route could not be read that time. Check `context.enabled` for `device_context`. |
| Device state | Battery, power mode, heat, appearance, orientation, locale, clock | `metadata.json` | `context.device` | `battery_level` 0 to 1; `battery_state`; `low_power_mode`; `thermal_state`; `interface_style`; `orientation`; `locale`; `uses_24_hour_clock` | `device_state` | Save device context with captures (on) | 1.1 | Nothing could be read, or the switch was off. A single missing field means that field was unknown (orientation is often unknown in the Share Extension). |
| Network | The network path when the capture was saved | `metadata.json` | `context.network` | `interface` (`wifi`, `cellular`, `wired`, `other`, `none`); `expensive`; `constrained` | `nw_path` | Save device context with captures (on) | 1.1 | No network path had been received yet, or the switch was off. |
| Previous capture | The capture saved just before this one on this phone, and the gap | `metadata.json` | `context.burst` | `previous_capture_id`; `seconds_since_previous`, seconds, one decimal | `last_saved` | Save device context with captures (on) | 1.1 | This is the first capture on the phone, the gap was negative, or the switch was off. |
| What was switched on | Which capture-time groups were on when saved | `metadata.json` | `context.enabled` | `groups`: `device_context`, `location` | `settings` | None (always written) | 1.1 | The capture predates format 1.1. |
| Altitude | Height of the location fix | `metadata.json` | `capture_location.altitude_meters` | meters above sea level; negative below | The location's `provenance` | Save location with captures (off) | 1.1 | No location, or the fix reported no valid altitude. |
| Altitude accuracy | How far off the altitude may be | `metadata.json` | `capture_location.vertical_accuracy_meters` | meters | The location's `provenance` | Save location with captures (off) | 1.1 | As altitude. |
| Speed | Speed of the location fix | `metadata.json` | `capture_location.speed_meters_per_second` | meters per second | The location's `provenance` | Save location with captures (off) | 1.1 | The fix had no valid speed. A one-shot fix often has none; it does not mean stationary. |
| Speed accuracy | How far off the speed may be | `metadata.json` | `capture_location.speed_accuracy_meters_per_second` | meters per second | The location's `provenance` | Save location with captures (off) | 1.1 | As speed. |
| Course | Direction of travel of the location fix | `metadata.json` | `capture_location.course_degrees` | degrees clockwise from true north, 0 to 360 | The location's `provenance` | Save location with captures (off) | 1.1 | The fix had no valid course (usually because the phone was not moving). |
| Course accuracy | How far off the course may be | `metadata.json` | `capture_location.course_accuracy_degrees` | degrees | The location's `provenance` | Save location with captures (off) | 1.1 | As course. |
| Motion | What Core Motion recorded from 10 minutes before to 10 minutes after the capture, plus the activity already in progress when that window opens | `enrichment.json` (device) | facet `motion_activity` | `at_capture` and up to 60 `segments`, each `{started_at, activities, confidence}`; the first segment is the activity in progress when the window opens, with its real start time (up to six hours before `window_start`), and `at_capture` can be that segment; `activities` from `stationary`, `walking`, `running`, `cycling`, `automotive`, `unknown`; `confidence` `low`, `medium`, `high` | `core_motion` | Motion activity (off) | 1.1 | Unknown. The switch was off or not yet run, permission is missing, the capture is more than about seven days old when first reached, or the device keeps no history. `empty` means history was queried and held no samples. |
| Weather | The weather for the hour of the capture at its location | `enrichment.json` (device) | facet `weather` | `temperature_celsius`, `apparent_temperature_celsius`, `relative_humidity_percent`, `precipitation_millimeters`, `cloud_cover_percent`, `wind_speed_meters_per_second`, `weather_code` (WMO), `condition`, `is_day`, `requested_latitude`, `requested_longitude` (2 decimals) | `open_meteo` | Weather (off) | 1.1 | Unknown. The switch was off or not yet run, the capture has no location, or the lookup has not succeeded. After repeated failures the facet can be `failed`; its `provenance` is then the error code rather than `open_meteo`, and `failed` means unknown, not negative. `empty` means Open-Meteo had no data for that hour. |
| Barcodes and QR codes | Codes read in image attachments | `enrichment.json` (device) | facet `barcodes` | items of `{attachment_id, symbology, payload, url?}`; payload up to 2,048 Unicode code points; up to 20 per attachment | `vision` | Barcodes and QR codes (on) | 1.1 | The switch was off or not yet run, or the capture has no image. `empty` means no code was found. |
| Language | Language of the capture's own text | `enrichment.json` (device) | facet `language` | items of `{source, language (BCP 47), confidence 0 to 1}` | `natural_language` | Language (on) | 1.1 | The switch was off or not yet run, or the text was shorter than 20 characters. `empty` means no language could be determined. |
| Sounds | What the built-in sound classifier heard in audio | `enrichment.json` (device) | facet `sound_classification` | items of `{attachment_id, labels: [{label, confidence 0 to 1}]}`; confidence 0.3 or more, up to 8 labels | `sound_analysis` | Sounds in recordings (on) | 1.1 | The switch was off or not yet run, or the capture has no audio. `empty` means no label reached 0.3. |
| Screenshot | A guess that an image is a screenshot | `enrichment.json` (device) | facet `screenshot` | items of `{attachment_id, reason}`; `reason` is `exif_user_comment` or `screen_size_match` | `heuristic` | Screenshots (on) | 1.1 | The switch was off or not yet run, or the capture has no image. `empty` means no image looked like one. |

Settings switches (default in parentheses) are on the phone under Settings, "Context" and "Enrichment". The device-context switch covers the four `context.*` observations other than `context.enabled`. Location extras ride on the location switch. Each facet kind has its own switch. Turning a kind on fills it in for existing captures.

## Telling "recorded and negative" from "not recorded"

Absence is ambiguous unless you check these in order:

1. `schema_minor` in `metadata.json`. Missing (or 0) means the capture predates these signals. No conclusion about context is possible.
2. `context.enabled`. Its `groups` say which capture-time groups were on. If `device_context` is in `groups`, a missing `context.audio_route`, `context.device` or `context.network` means that reading was unavailable that time. If it is not in `groups`, the person had the switch off. If `location` is not in `groups`, there is no location and no extras by choice, or permission was missing.
3. Facets. The device `enrichment.json` has a facet only when the phone ran the kind and had something to say. A missing facet means unknown, not "no". A facet with status `empty` is a recorded negative: the source was asked and found nothing.

Two examples: a capture with `context.enabled` listing `device_context`, and an `audio_route` whose `outputs` are `built_in_speaker`, is recorded evidence of no headphones and no car audio. A capture with no `motion_activity` facet says nothing about movement.

## Answering recall questions

These are hints for a reader, not rules the phone applies. The phone stores facts only.

### "While I was in a car"

Look for several of these together, and weigh them:

- `motion_activity`: `at_capture.activities` contains `automotive` (higher `confidence` is better), or `segments` show `automotive` across the window.
- `context.audio_route`: an output with `port_type` `car_audio` (a name such as "CarPlay" strengthens it), or a car's Bluetooth name on a `bluetooth_a2dp` or `bluetooth_hfp` output.
- `capture_location.speed_meters_per_second`: above about 3 m/s (faster than walking). Not decisive on its own, because a single fix often has no speed.

`automotive` and `stationary` together is normal at a red light. A passenger on a bus or train can look the same; the facts do not say who was driving.

### "While I was on headphones"

- `context.audio_route` outputs with `port_type` `headphones` (wired), `bluetooth_a2dp`, or `bluetooth_le`. A `bluetooth_a2dp` output can also be a speaker or a car, so check `port_name`.

### "Several captures in a row"

- `context.burst`: a small `seconds_since_previous` (for example under 60) means the previous capture was just before this one. Follow `previous_capture_id` backwards to find the run. A reader can also sort `captured_at` across packages; the entry saves the scan, and it covers captures made in the Share Extension and the app alike.

### Other combinations

- Walking or running: `motion_activity` with `walking` or `running`, and `speed_meters_per_second` around 1 to 4 m/s. There is no health data, so a gym session is not detectable.
- Indoors or outdoors, day or night: `weather` `is_day` and `condition`, with `capture_location.horizontal_accuracy_meters`.
- A photo of a screen: `screenshot` items for the attachment.
- A sign or menu with a code: `barcodes` items, whose `url` is recorded but never fetched.

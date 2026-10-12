# Strait

Flutter apps (Android first) that read live data from a Fisker Ocean through a vLinker FD+ BLE OBD dongle: **Strait** sends it to ABRP's Telemetry API, and **Ocean Discovery** is the tool used to find the data. `PLAN.md` is the source of truth for scope, phases and decisions; read it before starting work and update it when a decision changes.

## Naming
The app is **Strait**. Keep "Ocean", "Fisker" and "ABRP" out of the app's name, app ID and store-facing identity, since those names belong to others. Using them to describe what the app works with (for example "sends data to ABRP", "for the Fisker Ocean") is fine. Ocean Discovery is a personal tool and keeps its name.

## Hard rules
- **Read-only on the vehicle.** The transport layer may only send ELM327 `AT` setup commands, UDS `0x22` (ReadDataByIdentifier) and OBD mode `01` requests. Never add DTC clears (`0x14`), writes (`0x2E`), routines (`0x31`), resets (`0x11`) or session changes (`0x10`). The allow-list is enforced in code and covered by tests.
- **Don't keep the car awake.** The dongle is always plugged in. Nothing is sent on the CAN bus unless `ATRV` indicates the car is on, or the car is driving (the car's own speed at 10 km/h or more within the last 2 minutes) (PLAN.md §5.4).
- **No third-party diagnostic app code.** ELM327 / ISO-TP / UDS handling is written from the public standards.
- **Metric internally.** Signals, session files and ABRP payloads are metric. Imperial is a display-only conversion.
- **Secrets.** The ABRP API key and user token are entered by each user in the app and stored only in the app's secure storage. Never bundle them in a build, commit them, put them in local config files, log them or put them in URLs.

## Layout
- `packages/ocean_obd/`: shared package: `transport/` (BLE, allow-list, ATRV gate), `elm/`, `uds/`, `signals/`, shared `ui/` (connect, settings), `platform/` (foreground service, GPS)
- `packages/ocean_obd/assets/signals/ocean.json`: signal table (module, DID, decoding, ABRP field, poll rate, evidence); `sweep_os-*.json`: DIDs that answered in a sweep, without values
- `strait/`: Strait (`abrp/`, link UI). App ID `com.mstrdialup.strait`
- `discovery/`: Ocean Discovery (`discovery/` sweep, `recorder/`, sessions UI). App ID `com.oceanabrp.ocean_discovery`
- `docs/fisker-ocean/`: what we know about the Ocean's bus: `README.md` (findings with evidence) and `did-catalog.md` (generated)
- `tools/analyze/`: Python analysis of sessions, the catalog and bundled-list generators
- `data/sessions/`, `data/discovery/`: local recordings and sweeps, git-ignored (VIN and GPS)
- `keystore/`: shared signing key, git-ignored; CI restores it from secrets
- `docs/abrp/`: ABRP Telemetry API reference

## Commands
- `cd packages/ocean_obd && flutter test`: package tests (allow-list, ATRV gate, ELM, ISO-TP, UDS, decoders, units)
- `cd strait && flutter test` / `cd discovery && flutter test`: app tests
- `cd strait && flutter run` (or `discovery`): run on the connected Pixel
- CI: `.github/workflows/build-apk.yml` tests the package, then analyzes, tests and builds a debug APK of each app on every push

## Target device
Pixel 10 Pro, Android 17. The foreground service types are `connectedDevice` and `location`.

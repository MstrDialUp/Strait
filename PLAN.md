# Strait — Plan

A Flutter phone app (Android first) that reads live data from a Fisker Ocean through a vLinker FD+ OBD dongle and sends it to A Better Route Planner (ABRP) using the ABRP "Generic" live-data token.

Status: revision 12. The ABRP app is now named **Strait** (§6.7). Phase 2 works on the car (ABRP showed live data on 2026-09-29). The ABRP app and the discovery tool are now separate apps on a shared package (§6.6), and the findings are collected in `docs/fisker-ocean/`. Phase 1d under way: speed, pack current and pack voltage found (§6.4). Still needed: a charging session, dash SOC and tyre-pressure comparisons, and a gear test.

---

## 0. Decisions so far

| Topic | Decision |
|---|---|
| Platform | Flutter. Android is the target (Pixel 10 Pro, Android 17); iOS is a stretch goal. |
| Builds | GitHub Actions builds a debug APK on every push; you download and sideload it. |
| Units | Imperial by default, with a Settings toggle for metric. Internally everything is metric, because ABRP only accepts metric. |
| ABRP usage | ABRP runs on the same Android phone, in the foreground. Our app runs in the background for the whole trip. No Android Auto / CarPlay. |
| Car software | Ocean OS 2.2.3. Every recording stores the OS version, because an OTA update can move or change data identifiers. |
| Dongle | vLinker FD+ stays plugged in permanently. The app must never keep the car awake (see §5.4). |
| Discovery | You will record sessions on your daily commute and while charging. The app gets a Start/Stop Recording button and a checklist on stop (see §4). |
| ABRP credentials | The ABRP API key and user token are entered by each user in the app and stored only in the app (Android secure storage). They're never bundled in the build, committed, or kept in local config. Every user gets both from ABRP themselves: the API key under ABRP's self-service telemetry API keys, the token from the car's Generic connection. |
| Recorded data | Sessions and sweep results stay out of git. The repo is public, and these files contain the VIN and GPS tracks. You copy them into the git-ignored `data/sessions/` and `data/discovery/` locally for analysis. |
| Audience | Personal use first. Sharing with other Ocean owners later is possible, so nothing should block that path (see §7). |
| Development | Phase 1a onward is developed on your local machine (Flutter + Android SDK installed), with the Pixel connected over USB or wireless ADB. GitHub stays the source of truth; GitHub Actions still builds APKs as CI. See §9. |
| Reference code | The Unfiskered Go HTML has been removed from the repo. The code is written from public standards: the ELM327 datasheet, ISO 15765-2 (ISO-TP) and ISO 14229 (UDS). The only things carried over are the module addresses and data identifiers listed in §1, and each one is verified on your car before use. |

---

## 1. Known facts about the Ocean's diagnostic bus

Gathered from reviewing Unfiskered Go v6. Every item here is re-verified in Phase 1.

### 1.1 Adapter setup
ELM327 text commands over BLE, each ending with `\r`. A reply is complete when the `>` prompt arrives. Setup sequence: `ATZ` (reset), `ATE0` (echo off), `ATS0` (no spaces), `ATH1` (headers on), `ATSP6` (ISO 15765-4 CAN, 11-bit IDs, 500 kbps).

To address one module: `ATSH<tx>` sets the request ID, `ATFCSH<tx>` sets the flow-control header, `ATCRA<rx>` filters for the reply ID, then the UDS request is sent.

As implemented (Phase 1a): setup also sends `ATL0` (no linefeeds) and `ATFCSD300000` (flow-control data: clear to send, no block limit, no separation time). `ATFCSM1` (user-defined flow control) is enabled on the first physical module selection. For the 7DF functional address the app sends `ATSH7DF`, `ATAR` and `ATFCSM0`. Headers are only re-sent when the module changes. With `ATH1` the adapter prints raw frames including the ISO-TP PCI byte, and the app does the reassembly itself.

### 1.2 Module CAN IDs (request/response, hex)

| Module | Tx/Rx | Likely relevance |
|---|---|---|
| BMS | 7E1/7E9 | SOC, pack voltage/current, temperatures, SOH |
| VCU | 7C2/7CA | gear, vehicle state, speed, range, 12 V |
| BCM | 7C1/7C9 | odometer |
| MCU_F / MCU_R | 786/78E, 7F2/7FA | motor speed/torque → vehicle speed, power |
| OHC | 783/78B | on-board charger (AC charging) |
| PDU | 7F3/7FB | power distribution (DC charging?) |
| ESP | 7D0/7D8 | wheel speeds |
| ECC | 7F0/7F8 | climate: cabin/outside temp, HVAC power |
| PSM / TRM / GW / others | — | tyre pressures may be on one of these |

The functional (broadcast) request ID is 7DF.

### 1.3 Known data identifiers (UDS service 0x22)

| Value | Module | DID | Decoding |
|---|---|---|---|
| VIN | VCU | F190 | ASCII |
| Odometer | BCM | 3409 | uint32 ÷ 100 = km |
| HV state of charge | BMS | 2050 | uint16 ÷ 10 = % |
| 12 V battery | VCU | EFF9 | uint16 ÷ 1000 = V |
| Vehicle speed | VCU (any module) | EFF7 | uint16 ÷ 10 = km/h |
| HV pack current | BMS | 2004 | bytes 2–3 uint16 ÷ 10 − 2000 = A, + = discharge |
| HV pack voltage | BMS | 2107 | uint16 ÷ 10 = V |

The first four were verified against the dash on 2026-09-28 (Ocean OS 2.2.3, vLinker FD+ reporting `ELM327 v2.2`). Speed, current and voltage came from the 2026-09-29 drive (§6.4). Unverified candidates (SOC variants, battery temperature, cell voltage, tyre pressures) are in `ocean.json` with `verified: false` and an `evidence` note.

Not known yet: charging state, gear, outside and cabin temperature, HVAC power, SOH. The OBDb community signal set for the Ocean is empty.

### 1.4 Read-only rule
The app only sends ELM327 `AT` setup commands and UDS `0x22` ReadDataByIdentifier requests (plus standard OBD mode `01` probes on 7DF). A hard allow-list in the transport layer rejects everything else. In particular, the app never sends DTC clears (`0x14`), writes (`0x2E`), routines (`0x31`), resets (`0x11`) or session changes (`0x10`).

---

## 2. ABRP Telemetry API

Reference copies are in `docs/abrp/`: the Postman collection (`iternio-telemetry.json`), a PDF of the full page, extracts for `tlm/send` and `get_next_charge`, and the OAuth notes. What they confirm:
- Base URL `https://api.iternio.com/1/`. Every endpoint accepts GET or POST, with URL-encoded parameters (in the query string for GET, in the body for POST).
- Every response is JSON with two mandatory fields: `status` (`"ok"`, `"error"` or a more specific string) and `result`. The API returns HTTP 200 even for application errors; non-200 codes mean a bad API key or wrong usage.
- Endpoints in the `tlm/` group:
  - `send`: one telemetry point. The main endpoint.
  - `bulk`: several points in one call (`{"data":[{"token":…,"tlm_list":[…]}]}`). Used to flush points buffered during a signal loss (§5.1).
  - `get_carmodels_list`: ABRP model typecodes, used to find the Ocean's `car_model` code.
  - `get_telemetry`: the latest telemetry ABRP holds for a token. Used by a "Test link" button and during development to confirm data arrived.
  - `get_next_charge` / `set_next_charge`: the charge-to SOC goal of the current plan. A later "charging done" notification can use it.
- **Processing delay:** ABRP batches telemetry and waits 60 s for all sources. Data sent only within one 60 s window is not processed until data for the next minute arrives. A short test must therefore send for at least 2 minutes.
- **Rate:** one point every 5 s is the desired rate; slower than one per 30 s is recommended against.
- **Errors:** when `status` is not `"ok"`, details are in an `errors` property of the response.
- OAuth2 (`ABRP-OAuth.txt`) uses a client ID, a redirect URI, and scopes `set_telemetry` / `get_telemetry`. Only needed for sharing (§7).

### 2.1 Endpoint
`https://api.iternio.com/1/tlm/send`

- `api_key`: identifies the sender. Telemetry keys are now self-service: ABRP → API keys → telemetry ("Personal telemetry keys for posting and reading your ABRP live data"). No email to Iternio is needed. Allow posting and, if offered, reading (for the "Test link" check). The key goes in the header `Authorization: APIKEY <key>` (preferred over the query parameter, so it doesn't end up in URLs or logs).
- `token`: identifies your car in ABRP. Where to find it: ABRP → Settings → your Ocean → Modify connections → Generic → Link.
- `tlm`: a JSON object with the telemetry fields, including an optional `car_model` typecode (e.g. `chevy:bolt:17:60:other`). The Ocean's typecode comes from `get_carmodels_list`.
- The documented example sends `token` and `tlm` as URL query parameters with POST.

### 2.2 Fields
- **High priority:** `utc` (epoch seconds), `soc` (%), `power` (kW; positive = discharging, negative = charging), `speed` (km/h), `lat`, `lon`, `is_charging`, `is_dcfc`, `is_parked`.
- **Lower priority:** `capacity`, `soe`, `soh`, `heading`, `elevation`, `ext_temp`, `batt_temp`, `voltage`, `current`, `odometer`, `est_battery_range`, `hvac_power`, `hvac_setpoint`, `cabin_temp`, `tire_pressure_fl/fr/rl/rr` (kPa).
- **Consumption calibration:** ABRP needs `speed`, `power` and `is_charging` at least every 10 s.
- **Units:** everything is sent in metric; ABRP converts for display.

### 2.3 Field sources

| Field | Source | Status |
|---|---|---|
| `utc`, `lat`, `lon`, `heading`, `elevation` | phone GPS | available |
| `speed` | VCU EFF7 | verified; reads ≈3 % below GPS, like the odometer |
| `soc` | BMS 2050 | verified once; up to 1.1 points above the dash since, so 2047 is also a candidate (§6.4) |
| `odometer` | BCM 3409 | verified |
| `current`, `voltage` | BMS 2004, 2107 | verified by the energy check (§6.4) |
| `power` | computed: voltage × current ÷ 1000 | from the two above |
| `is_charging`, `is_dcfc` | unknown | needs a charging session; fallback: current < −5 A while stationary |
| `is_parked` | unknown | needs a gear test; fallback: speed 0 for 60 s |
| `batt_temp` | BMS 2089 ÷ 100 (candidate) | unverified |
| `tire_pressure_*` | BCM 3427, 4 bytes (candidate) | scale and wheel order unverified |
| `ext_temp`, `soh`, `est_battery_range`, `hvac_power`, `cabin_temp` | not found | nice to have |

---

## 3. Architecture

```
 vLinker FD+ ──BLE──► transport/   (GATT UART, command queue, '>' framing, allow-list)
                         │
                         ▼
                      elm/         (init, ATRV, header/filter switching)
                         │
                         ▼
                      uds/         (ISO-TP reassembly, 0x22 requests, negative responses)
                         │
          ┌──────────────┴──────────────┐
          ▼                             ▼
      recorder/                     signals/ + poller/
   (discovery sweeps, raw          (decoded values from
    session logs, checklist)        signals/ocean.json)
          │                             │        phone GPS
          ▼                             ▼            │
     export (share sheet)          telemetry snapshot ◄┘
                                        │
                                        ▼
                                     abrp/ (uploader, keeps only the latest snapshot while offline)
```

### 3.1 Flutter packages (initial picks)
- `flutter_blue_plus`: BLE. Licence checked (v2.3, FlutterBluePlus License 1.5): free for personal, nonprofit and educational use, and the app passes `License.nonprofit` to `connect()`. Any commercial or for-profit use needs a paid licence. The BLE UART characteristics are discovered at connect time (preferring services FFF0, FFE0, 18F0), because ELM327 BLE adapters differ.
- `geolocator`: GPS.
- `flutter_foreground_task`: Android foreground service with a persistent notification.
- `flutter_secure_storage`: ABRP token and API key.
- `path_provider` + `share_plus`: session export.
- `http`: ABRP upload.

### 3.2 Android background requirements
- A foreground service with types `connectedDevice` and `location`, started while the app is visible. Our app then keeps running while ABRP is in front and the screen is off.
- Permissions: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`, `ACCESS_FINE_LOCATION`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE_*`.
- Ask the user to exempt the app from battery optimisation. Some Android skins kill background apps otherwise.
- Target device: Pixel 10 Pro, Android 17. The app targets the latest Android SDK supported by the current Flutter stable release and declares its foreground service types explicitly. Pixels are less aggressive about killing background apps than some other brands, but the battery-optimisation exemption is still requested.

### 3.3 Units
- All values are stored and sent in metric.
- The UI converts at display time: km/h ↔ mph, km ↔ mi, °C ↔ °F, kPa ↔ psi, Wh/km ↔ mi/kWh.
- Settings has an Imperial/Metric toggle, defaulting to Imperial.
- Session exports stay metric, so the analysis never depends on the display setting.

### 3.4 Repository layout
```
packages/ocean_obd/   shared package: transport, ELM, ISO-TP, UDS, signals, connect/settings UI, foreground service, GPS
packages/ocean_obd/assets/signals/   ocean.json signal table; sweep_os-*.json DID lists
strait/               Strait, the ABRP link app
discovery/            Ocean Discovery (sweep, recorder, sessions)
docs/fisker-ocean/    findings about the Ocean's bus (README.md, did-catalog.md)
docs/abrp/            ABRP API reference copies
tools/analyze/        Python analysis of sessions; catalog and DID-list generators
data/sessions/        exported recordings (JSONL), git-ignored
data/discovery/       exported discovery.json sweep results, git-ignored
keystore/             shared signing key, git-ignored
.github/workflows/    package tests and APK builds
CLAUDE.md
PLAN.md
```

---

## 4. Discovery app (Phase 1)

The first build is the scanner. It shares the transport, ELM and UDS code with the final app, so none of the work is thrown away.

### 4.1 Screens
1. **Connect:** scan for the vLinker, connect, run the setup sequence. Shows the adapter ID (`ATI`), adapter voltage (`ATRV`), VIN, and the four known values (§1.3), so they can be checked against the dash.
2. **Discovery sweep:** run once while parked with the car in Ready. For each module in §1.2, it sends `0x22` over candidate DID ranges and records which ones respond: `2000–20FF`, `2100–21FF`, `3400–34FF`, `D000–D1FF`, `EF00–EFFF`, `F100–F1FF`, `F400–F4FF`, `FD00–FDFF`. It also probes OBD mode `01` PIDs on 7DF (`0100`, `010D` speed, `015B` battery remaining, and others).
   - At roughly 80 ms per request, one 256-DID range takes about 20 s per module, and the full sweep takes roughly 15–25 minutes. The sweep saves its progress, so it can run in several short sittings.
   - Its output is a "responding DIDs" list, which recordings use.
   - Also a 5-second passive listen (`ATMA`) to check whether the OBD port carries any broadcast traffic. If it does, many values may be readable without polling at all.
3. **Record:**
   - A large **Start Recording** button. After you press it you can lock the phone and drive, because recording runs in the foreground service.
   - While recording, the app polls every responding DID in a round-robin, weighted so BMS, VCU and MCU are read most often. It also logs GPS position, speed and heading once a second.
   - **Stop Recording** opens the checklist (§4.2). The session is then saved.
4. **Sessions:** a list of saved sessions with duration, size and checklist summary, plus a share button that exports the JSONL for copying into the local `data/sessions/`.

### 4.2 Stop checklist
Tick everything that happened during the session:

- [ ] Parked, car in Ready, not moving
- [ ] City driving (under 60 km/h)
- [ ] Highway driving
- [ ] Hard acceleration
- [ ] Strong regenerative braking
- [ ] Reversing
- [ ] Heating used
- [ ] Air conditioning used
- [ ] AC charging (Level 1 or 2)
- [ ] DC fast charging
- [ ] Charging started or stopped during the session
- [ ] Preconditioning
- [ ] Hyper / Earth / Fun mode changed (list which)

Optional dash readings at stop, which help match values: SOC %, range shown, outside temperature, odometer. Free-text notes.

### 4.3 Session file (JSONL, one object per line)
- The first line is a header: app version, car OS (default 2.2.3, editable), adapter `ATI`, VIN, start time.
- Then one line per reading: `{"t":…, "type":"did", "mod":"BMS", "did":"2050", "raw":"03E8"}` or `{"t":…, "type":"gps", "lat":…, "lon":…, "spd":…, "hdg":…}`.
- The last line is the footer: stop time, checklist, dash readings, notes.

### 4.4 Analysis (`tools/analyze/`)
Python scripts I run on the sessions in your local `data/sessions/`:
- **Speed:** find DIDs that move in step with GPS speed, testing common scalings (÷10, ÷100, signed/unsigned, byte offsets).
- **Power and charging:** find DIDs in a plausible pack-voltage range (~300–450 V), and DIDs that change sign between driving and charging sessions (current). Check power ≈ V × I against regen and acceleration events.
- **Gear and state:** find DIDs with a small set of values that change only when parked, driving or reversing.
- Output a candidate list with plots. Confirmed signals go into `packages/ocean_obd/assets/signals/ocean.json`.

### 4.5 Safety
- Discovery sweeps run **only while parked**. While driving, the app polls only DIDs that already responded in a sweep.
- The request rate is capped, around 10–12 per second, to keep load on the diagnostic bus low.
- Everything is read-only (§1.4).
- The app is never operated while driving. Start before the trip, stop after.

---

## 5. ABRP link app (Phases 2–4)

### 5.1 Behaviour
- Setup: the user pastes their own API key and token into the app once (§0, ABRP credentials).
- While linked: poll the confirmed signals at 1 Hz (SOC, speed, power) and slower for odometer and temperatures.
- Upload every 5 s while driving and every 30 s while parked or charging.
- On network loss: buffer points (capped at about 1 hour at 5 s spacing) and flush them with `tlm/bulk` on reconnect. The buffered points still help ABRP's consumption model for your car.
- Settings has a "Test link" button: send points for 2 minutes (because of the 60 s processing delay), then read them back with `get_telemetry`.

### 5.2 Status screen
Connection state, the latest values, the last upload time and result, and the ABRP error text if any.

### 5.3 Auto-start
While the phone is near the car the dongle is always advertising, so the app can connect automatically. Connecting does not mean polling.

### 5.4 Keeping the car asleep (dongle stays plugged in)
- The app first reads the adapter's own supply voltage with `ATRV`. This reads the voltage at the OBD port pin and sends **nothing on the CAN bus**.
- Around 13.0 V or higher means the DC-DC converter is running: the car is on or charging. Below that, the car is off.
- Car on: start polling and uploading.
- Implemented in `transport/bus_gate.dart`: every bus command (hex requests and `ATMA`) is refused unless the latest `ATRV` reading is ≥ 13.0 V and at most 90 s old. `AT` setup commands are never gated because they don't reach the bus.
- Car off: send nothing on the bus. Re-check `ATRV` every 60 s, then disconnect BLE after 10 minutes. A car-on reading taken elsewhere (e.g. "Re-check voltage") ends the 60 s wait early.
- While the ABRP link is polling, one low or unreadable `ATRV` pauses polling (nothing is sent on the bus) and is re-checked every 5 s; the car only counts as off after 3 such readings in a row. The link keeps a short event log on the ABRP tab saying why it called the car off.
- The Connect screen re-reads `ATRV` every 30 s while connected (skipped if another screen read it in the last 30 s), so its car-on reading doesn't go stale after 90 s.
- If a UDS request gets no answer, stop polling and fall back to the `ATRV` check.
- If an adapter command times out, its late reply is discarded before the next command is sent (waiting up to 1 s), so replies can't get out of step with commands.
- Phase 4 checks the vLinker FD+ sleep settings, and includes an overnight 12 V test with the dongle plugged in and the app installed.

---

## 6. Phases

| Phase | What | Who |
|---|---|---|
| 0 | Create a personal ABRP telemetry API key. Get the ABRP Generic token. Set up local development (§9.2). | you |
| 1a | Flutter scaffold, BLE transport, ELM/UDS layers with unit tests, Connect screen verifying the known values. | me → you test |
| 1b | Discovery sweep, recorder, checklist, session export. | me → you test |
| 1c | Record commute and charging sessions; copy them into the local `data/sessions/`. | you |
| 1d | Analysis, confirmed signal table. | me |
| 2 | ABRP MVP: SOC, speed, power, voltage, current, odometer, GPS, inferred `is_parked` / `is_charging`; foreground service; key and token settings; `ATRV` wake logic. | me → you test |
| 3 | Add power, voltage, current, charging flags, gear and temperatures from Phase 1 results. | me → you test |
| 4 | Hardening: overnight 12 V test, reconnect handling, battery-optimisation guidance, trip CSV export. | both |
| Stretch | iOS build (CoreBluetooth background mode, Apple developer account). Sharing with other owners (§7). | later |

### 6.1 Phase 1a status
Done in `app/`:
- `transport/`: `CommandPolicy` allow-list (AT setup commands, `0x22`, mode `01`; everything else throws), `BusGate` (§5.4), `ElmTransport` (serial command queue, `>` framing, ~85 ms minimum spacing between bus requests), `BleUartLink` (flutter_blue_plus).
- `elm/`: setup sequence, `ATI`, `ATRV`, module addressing, reply parsing (frames and status words such as `NO DATA`).
- `uds/`: ISO-TP reassembly (single, first, consecutive and flow-control frames; sequence checks), `0x22` and mode `01` reads with negative-response handling (NRC `0x78` "pending" is skipped).
- `signals/`: `ocean.json` holds the modules from §1.2 and the four known DIDs from §1.3, all `verified: false` until they're checked against the dash.
- `ui/`: Connect screen (scan, connect, adapter ID, `ATRV` with car on/off, read the known values with raw hex, adapter log, Imperial/Metric toggle).
- 96 unit tests (allow-list, gate, framing, ISO-TP, UDS, decoders, units), plus `.github/workflows/build-apk.yml`.

To test on the car: open the Connect screen, scan, and tap the vLinker. Check `ATI` and `ATRV` with the car off (it should show "Car off", and no bus request is possible). Then put the car in Ready, tap "Read known values", and compare VIN, SOC, odometer and 12 V with the dash. Mark each confirmed signal `verified: true` in `ocean.json`.

### 6.2 Phase 1b status
Done in `app/`:
- **Discover tab** (`discovery/`): sweeps the §4.1 DID ranges on every module in `ocean.json` (2,304 DIDs per module, about 30 min for all nine at the rate cap), then probes OBD mode `01` PIDs on 7DF and does a 5 s passive `ATMA` listen. Before starting it asks you to confirm you're parked in Ready. Progress is saved to `discovery.json` every 32 requests and on stop, so it resumes where it left off. A module that doesn't answer its first 8 requests is marked silent and skipped, and one that returns "serviceNotSupported" is skipped too. `requestOutOfRange` (NRC 0x31) is treated as "DID doesn't exist". Any other NRC is recorded as "exists but refused". The sweep re-checks `ATRV` every 30 s and pauses if the car turns off. "Share results" exports `discovery.json` (copy it into the local `data/discovery/`).
- **Record tab** (`recorder/`): polls every DID that answered with data in the sweep, plus the known signals, in a weighted round-robin (BMS, VCU and MCUs get 3 turns per 1 for the others). GPS is logged about once a second. `ATRV` is re-read every 30 s. While the car is off nothing is polled and only GPS is recorded. After 20 unanswered requests in a row the gate closes until the next voltage check.
- **Foreground service**: flutter_foreground_task with types `connectedDevice|location` and a wake lock. It only keeps the process alive: BLE and GPS stay in the main isolate, because flutter_blue_plus is bound to the main Flutter engine. Swiping the app away from recents ends the recording, and the session is then saved without a footer; the Sessions list marks it "interrupted".
- **Stop checklist** (§4.2) with optional dash readings typed in display units and converted to metric before saving, plus notes.
- **Session files** (§4.3): `session_YYYYMMDD_HHMMSS.jsonl` in the app's documents folder. Line types: `header`, `did` (`raw` hex after the DID echo), `nrc`, `gps` (`spd` km/h, `hdg`, `alt`, `acc`, `fix_t`), `atrv` (`v`), `event`, `footer` (`checklist` keys, `dash` {`soc`, `range_km`, `ext_temp_c`, `odometer_km`}, `notes`). `t` is epoch ms.
- **Sessions tab**: duration, size, OS version and checklist summary, with share and delete buttons.
- **Settings** (gear on Connect): Imperial/Metric and the car OS version, stored in `settings.json`.
- 111 unit tests.

To test: Connect, then on Discover run the sweep while parked in Ready (it can be split over several sittings). Then on Record, start before a commute, lock the phone, and stop afterwards. Share the session and `discovery.json` from the app and copy them into the local `data/sessions/` and `data/discovery/`.

### 6.3 First sweep and sessions (2026-09-28, OS 2.2.3)
**Sweep:** it finished on all nine modules; 272 DIDs returned data, and ESP `FDxx` returned 15 "generalReject" (NRC 0x10).
- **No standard OBD:** none of the mode `01` PIDs got an answer on 7DF.
- **No usable broadcast traffic:** the passive `ATMA` listen saw one frame repeated with `<DATA ERROR` until `BUFFER FULL`, so every value has to be polled. `ATMA` isn't worth repeating.
- **Live data in the swept ranges is only on BMS `20xx`/`21xx` (≈65 DIDs), BCM `34xx` (≈40) and ESP `FDxx` (8).** VCU, MCU_F/R, OHC, PDU and ECC answered only identification DIDs (`EFFx`, `F1xx`). `EFF8` on every module holds the same odometer ×100, and `EFF9` is the 12 V value everywhere.
- **Candidates from the sweep snapshot**, to be confirmed with recordings:

| Candidate | DIDs | Snapshot |
|---|---|---|
| pack voltage | BMS `2003`, `2107`, `2109`, `2117` | 0x0F21–0x0F24 ≈ 387 V at ÷10 |
| cell voltage min/max/avg | BMS `2136`–`2138` | 3.79–3.81 V at ÷1000 |
| cell temperatures | BMS `2089`–`2094` | ≈22.3 °C at ÷100 (it was ≈22 °C outside) |
| SOC variants | BMS `2047`–`2049` | 59.9–61.2 % at ÷10 |
| current (offset?) | BMS `2004` | 0x4E3A |
| wheel speeds | ESP `FD00` | 4 × uint16 |

**Sessions:** four sessions: a 32-minute mixed drive and three short ones. All were recorded before the sweep finished, so they only polled the four known signals.
- **Odometer:** BCM `3409` moves in 0.1 km steps and matched GPS distance within GPS noise (22.6 vs 23.3 km, 1.5 vs 1.7 km, 1.3 vs 1.45 km).
- **SOC:** BMS `2050` read 58.2–59.1 % at the end of sessions where the dash showed 58 %. Check which DID tracks the dash SOC, because ABRP should get the displayed value.
- **BLE drop:** one short session ended when the link dropped and the recorder stopped.
- **Slow polling:** only ≈4.4 reads/s, because every read switched modules (three extra adapter round trips each time).

**Fixes made after this review:**
- The recorder reads identification DIDs (`EFxx`, `F1xx`, and the VIN) once per session, the first time the car is on. It polls only the live candidates plus the known signals.
- `PollSchedule` reads each module's DIDs back to back. Each round reads every priority module (BMS, VCU, MCU_F/R, ESP), then one other module in rotation.
- **Auto-reconnect:** after an unexpected BLE drop, Connect retries with 2/5/10/20/30 s back-off. The recorder keeps logging GPS, logs `link_lost` / `link_restored`, and resumes polling after a fresh `ATRV` check.

**Still needed:**
1. A recording with the sweep results and the fixes: a mixed drive (city, highway, hard acceleration, strong regen, reversing, parked in Ready), plus AC or DC charging if possible.
2. Phase 1d analysis of that recording.
3. **Only if (1) doesn't give gear and charging state:** a wider sweep of VCU, PDU and OHC. About 1.5 h per module at the rate cap for the full 0x0000–0xFFFF range; it can resume and can run while charging.

### 6.4 First drive with all DIDs (2026-09-29)
A 32-minute mixed drive (city, highway, hard acceleration, strong regen, reversing, parked in Ready). It was recorded with the 1b build, so it polled all 272 DIDs at about 5.4 reads/s: BMS DIDs about every 33 s, the others about every 100 s. Of the 272 DIDs, 101 changed. Analysis: `tools/analyze/analyze.py`.

- **Speed: `EFF7` on every module**, uint16 ÷ 10 = km/h, r = 0.999 against GPS. It reads ≈3 % below GPS, the same gap as the odometer against GPS distance, so it's consistent with the car's own odometer. ESP `FD00` holds four wheel speeds (uint16 each, ≈0.0288 km/h per bit).
- **The `EFxx` DIDs are live**: `EFF6` is a clock, `EFF7` speed, `EFF8` odometer, `EFF9` 12 V. The §6.3 fix wrongly read them once per session; now only `F1xx` is read once.
- **Pack current: BMS `2004`**, bytes 2–3 uint16 × 0.1 − 2000 A, positive while discharging. Over the drive it integrates to 5.75 kWh; the SOC drop gives 5.54 kWh at 113 kWh. BMS `2016` (int32 × 0.1 A) tracks it but reads 0 A at idle when `2004` shows ≈7 A, so it probably excludes auxiliary loads.
- **Pack voltage: BMS `2107`** (also `2109`, `2117`), uint16 ÷ 10: 391–413 V, sags under load. It equals ≈102 × the cell voltage in `2136`–`2138` (3.84–4.04 V).
- **SOC:** `2050` read 75.1 % when the dash showed 74 %. `2047`/`2048`/`2049` sit 1.2–2.4 points lower (they look like max/min/average) and `2047` read 73.9 %. Which one the dash shows is still open.
- **Tyre pressures: BCM `3427`**, 4 bytes, zero until the TPMS sensors wake after ≈20 min of driving, then `C1 C1 C3 C2`. At 0.2 psi per bit that's 38.6–39.0 psi; the scale and wheel order need the dash.
- **Other states:** BCM `3403`/`3404` changed when the doors locked after pulling away, and BMS `2061` reads 01 when parked in Ready and 05 while driving. Neither is a gear signal, and nothing in the swept ranges changed only when reversing.
- **Battery temperature candidate: BMS `2089`–`2094`**, 22.1–22.3 at ÷100. It was 22.3 the day before as well, so it's plausible for a thermally managed pack but not confirmed.

**Still needed:**
1. **A charging session**, AC and DC if possible, to find `is_charging`, `is_dcfc` and the charging current sign. A few minutes of recording before and after plugging in are enough.
2. **SOC against the dash:** at two or three different charge levels, tap "Read known values" on Connect and note the dash SOC at the same moment. Compare `soc` (2050) with `soc_2047`/`2048`/`2049`.
3. **Tyre pressures against the dash:** once, after a drive of 20+ minutes, read the four dash pressures and "Tyre pressure 1–4" on Connect together.
4. **A gear test:** stationary in Ready, P → D → N → R → P, about 20 s each, noting the times. If nothing in the current DIDs follows the gear, the VCU needs a wider sweep (§6.3). For ABRP the fallback (speed 0 for 60 s = parked) works in the meantime.
5. **A recording with the new build**, for faster sampling: the gear test and charging session will already give this.

### 6.5 Phase 2 status (ABRP link)
Done in `app/`:
- **`abrp/credentials.dart`**: the user's own API key and token in Android secure storage (`flutter_secure_storage`). They're shown masked (last four characters), never logged, and scrubbed from error text. Android backup is off (`allowBackup="false"`), so they never leave the phone.
- **`abrp/abrp_client.dart`**: `tlm/send`, `tlm/bulk` and `tlm/get_telemetry`. The key goes in `Authorization: APIKEY …`, and the token in the POST body, so neither is ever in a URL. Results are sorted into ok, network (buffer and retry), HTTP (usually the key) and rejected (ABRP's `errors` text).
- **`abrp/vehicle_state.dart`**: the latest values by ABRP field, with maximum ages (15 s by default, 3 min for the odometer).
  - `power` is voltage × current.
  - The car's speed is used, falling back to GPS speed.
  - Parked means speed below 1 km/h for 60 s.
  - Charging means current below −5 A while stationary, and DC means charging above 12 kW (the on-board charger tops out at 11 kW).
  - A point is only sent when there is fresh car data.
- **`abrp/uploader.dart`**: every 5 s while driving and 30 s while parked or charging. Network failures buffer up to 720 points (1 h), dropping the oldest first. Buffered points are flushed with `tlm/bulk` in batches of 100 once sending works again. Rejected points aren't retried.
- **`abrp/live_poller.dart`**: polls only **verified** signals that map to an ABRP field, each at its `poll_s` (SOC, speed, current and voltage at 1 s, odometer at 60 s). It follows §5.4:
  - nothing goes on the bus unless `ATRV` shows the car on;
  - `ATRV` is re-read every 30 s while on and every 60 s while off;
  - 10 unanswered reads close the gate;
  - after 10 minutes with the car off the link stops and the adapter disconnects, unless a recording is still using it.
- **ABRP tab**: key and token entry with help text, Start/Stop, car and upload status, the latest values and the inferred state, plus "Check what ABRP received" (`get_telemetry`; needs a key that is allowed to read).
- The foreground service is reference-counted, so recording and the ABRP link can run at the same time. GPS is one shared platform stream.
- 155 unit tests, including a mocked ABRP server.

Not yet: auto-start when the adapter is in range (§5.3), the real charging and gear signals (Phase 3), and `batt_temp` and tyre pressures (still unverified).

To test on the car:
1. Create a personal telemetry API key in ABRP (allow posting and reading).
2. Enter the key and the Generic token on the ABRP tab.
3. Connect, then Start sending.
4. Drive for at least 2 minutes (ABRP has a 60 s processing delay) with ABRP open.
5. Check that ABRP shows live SOC and speed, and use "Check what ABRP received".

### 6.6 Split into two apps (2026-09-29)
Phase 2 was confirmed on the car: with the link running, ABRP showed live SOC, power, voltage and odometer from the "Api" source. The code is now split:
- **`packages/ocean_obd`** holds everything that talks to the car: transport and allow-list, ATRV gate, ELM327, ISO-TP, UDS, the signal table and its assets, the connect/reconnect controller, the Connect and Settings screens, the foreground service and GPS. Future Ocean apps depend on this package.
- **`app/` (Ocean ABRP Connect, renamed Strait in §6.7)** has only the ABRP and Car tabs. At the split it kept the app ID `com.oceanabrp.ocean_abrp_connect`.
- **`discovery/` (Ocean Discovery)** has Connect, Discover, Record and Sessions, with the app ID `com.oceanabrp.ocean_discovery`, so both install side by side. Its sweep results and sessions start empty; recording uses the bundled DID list.
- CI tests the package, then builds both APKs (`strait-<run>.apk` since §6.7, `ocean-discovery-<run>.apk`), both signed with the shared key (now in `keystore/` at the repo root).
- **Knowledge base:** `docs/fisker-ocean/README.md` collects the adapter behaviour, module map, decoded signals with their evidence, candidates, what isn't there, timing and open questions. `did-catalog.md` lists every DID that answered, generated by `tools/analyze/catalog.py` without per-car values.

### 6.7 Renamed to Strait (2026-09-29)
To avoid names that belong to others, the ABRP link app is now **Strait**: display name, Dart package `strait`, directory `strait/`, Android app ID `com.mstrdialup.strait` (iOS bundle ID the same), APK `strait-<run>.apk`. The GitHub repository is now `MstrDialUp/Strait`, and GitHub redirects the old URL. "Fisker", "Ocean" and "ABRP" only appear to describe what the app works with; the root `README.md` states that it isn't affiliated with them. Ocean Discovery keeps its name and ID (personal use).
- The app ID is based on the domain `mstrdialup.com`. Nothing needs to be set up on the domain: app IDs are names only, and neither sideloading nor Play checks domain ownership. The domain would only matter later for web links into the app (Android App Links need `/.well-known/assetlinks.json` on it) or as an OAuth redirect URI.
- Because the app ID changed, Android treats Strait as a new app: install it, enter the ABRP key and token again, then uninstall the old "Ocean ABRP" app.
- Before a public release: choose a license for the repository; `flutter_blue_plus` is free only for personal and nonprofit use (§3.1); decide whether each user brings their own ABRP key (current design) or Iternio OAuth is needed.

APK delivery: `.github/workflows/build-apk.yml` runs `flutter analyze`, `flutter test` and `flutter build apk --debug` on every push. Each app's APK is uploaded as the workflow artifact `<app>-<run>-<branch>`, containing `<app>-<run>.apk` (`strait`, `ocean-discovery`). You sideload it on the Pixel ("Install unknown apps" enabled for your browser or Files app).
- **Build stamp:** the run number is the Android versionCode and the version name `0.1.<run>`, so App info shows it and every build is newer than the last. The Connect screen, Settings and session headers show `build <run> · <commit> · <branch>`.
- **Signing:** every build, CI or local, is signed with one shared key, so a new APK installs over the old one without uninstalling (uninstalling would delete unexported sessions, sweep results and the ABRP credentials). The keystore lives in the git-ignored `keystore/` at the repo root (`ci-debug.jks` plus `keystore.properties`), and CI restores it from the repository secrets `CI_KEYSTORE_B64` and `CI_KEYSTORE_PASSWORD`. Without it, builds fall back to a machine-specific debug key and CI logs a warning. Until 2026-09-29 each CI run used a new throwaway key, which is why updating failed ("Something went wrong") and an older build stayed installed. Back up the keystore; if it's lost, make a new one and uninstall once.
- The DID list from the first sweep is bundled with the app (`packages/ocean_obd/assets/signals/sweep_os-2.2.3.json`, regenerated with `tools/analyze/export_did_list.py`), so recording works on a fresh install too.

---

## 7. If the app is shared later
- Each user supplies their own ABRP Generic token; the app is unchanged for that.
- Each user supplies their own API key as well as their token (§0), so nothing needs to ship inside the app. Iternio's OAuth2 flow could later replace pasting the token, but it needs a client ID from Iternio.
- Other Ocean owners may be on different OS versions, so the signal table needs per-OS-version entries.
- Check the licence terms of each dependency, particularly `flutter_blue_plus`.

---

## 8. Remaining open questions
None at the moment.

---

## 9. Development environment

### 9.1 Why local
- **Hardware:** Phase 1 depends on the BLE link to the vLinker and on the car. Only your machine and phone can reach them.
- **Iteration speed:** `flutter run` on the Pixel gives hot reload and live logs (`flutter logs` / logcat). Debugging BLE timing through downloaded CI builds would take one full CI run per attempt.
- **The cloud container can't build Android:** its network policy blocks the Android SDK download host (`dl.google.com`). It could run pure-Dart unit tests, but not build or run the app.

### 9.2 Setup
1. Clone the repo on your machine.
2. Confirm `flutter doctor` passes for Android. Enable USB debugging (or wireless debugging) on the Pixel.
3. Run Claude Code locally in the repo (CLI, desktop app or IDE extension). `CLAUDE.md` and this plan carry the project context into that session.
4. Use short-lived feature branches and PRs into `main`, so GitHub Actions runs on every change.

### 9.3 What stays in the cloud (optional)
Anything that doesn't need hardware, such as analysing recorded sessions (`tools/analyze/`) or reviewing PRs, can run in either environment, because everything goes through the repo.

---

## Appendix A — Draft email to Iternio (not needed for personal keys)

Kept for reference: telemetry API keys are now self-service in ABRP, and each user enters their own (§0). This is only relevant if the app ever needs Iternio's OAuth2 client setup.

> **To:** contact@iternio.com
> **Subject:** Telemetry API key request — Fisker Ocean OBD live data app
>
> Hello,
>
> I'm requesting a Telemetry-Only API key for a small app I'm building to send live data from my Fisker Ocean to ABRP.
>
> Fisker no longer operates, and the third-party app that used to provide ABRP live data for the Ocean has removed that feature. My app reads vehicle data (state of charge, speed, battery power, charging state, odometer) from a Bluetooth OBD-II adapter, adds the phone's GPS position, and sends it to `/1/tlm/send` using the user token from ABRP's Generic live-data connection.
>
> - App name: Strait
> - Platform: Android (Flutter); iOS possibly later
> - Use: personal and non-commercial for now. I may share it free with other Fisker Ocean owners later. If so, please let me know whether one API key can be bundled in a distributed app, or whether I should use your OAuth2 flow.
> - Expected rate: one request every 5 s while driving, every 30 s while charging, for one vehicle.
>
> Thank you,
> [Your name]

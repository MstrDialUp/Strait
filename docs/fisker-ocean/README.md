# Fisker Ocean diagnostic bus: what we know

Everything learned while building Strait about talking to a Fisker Ocean through its OBD port: the adapter, the bus, the modules, the data identifiers (DIDs) and how to decode them. It's written for anyone building another Ocean app, and it records the evidence behind each claim.

- **Car:** one 2023 Fisker Ocean, Ocean OS **2.2.3**. An OTA update can move or change DIDs, so re-check after an update.
- **Adapter:** vLinker FD+ over Bluetooth LE, reporting `ELM327 v2.2`.
- **Dates:** sweep 2026-09-28, drives 2026-09-28 and 2026-09-29, ABRP link confirmed 2026-09-29.
- **Code:** `packages/ocean_obd` (transport, ELM327, ISO-TP, UDS, signal table) implements everything here. The machine-readable signal table is `packages/ocean_obd/assets/signals/ocean.json`.
- **Full DID list:** [did-catalog.md](did-catalog.md), every DID that answered, per module.

## Contents
1. [Safety rules](#1-safety-rules)
2. [Adapter and connection](#2-adapter-and-connection)
3. [The bus and its modules](#3-the-bus-and-its-modules)
4. [Decoded signals](#4-decoded-signals)
5. [Candidates and observations](#5-candidates-and-observations)
6. [What didn't work or isn't there](#6-what-didnt-work-or-isnt-there)
7. [Timing and throughput](#7-timing-and-throughput)
8. [Open questions](#8-open-questions)
9. [How to reproduce or extend this](#9-how-to-reproduce-or-extend-this)

## 1. Safety rules
These held for all the work below and should hold for any Ocean app:
- **Read-only.** Send only ELM327 `AT` setup commands, UDS `0x22` ReadDataByIdentifier and OBD mode `01`. Never send `0x14` (clear DTCs), `0x2E` (write), `0x31` (routines), `0x11` (reset), `0x10` (session change), `0x27` (security access) or `0x3E` (tester present). `packages/ocean_obd/lib/transport/command_policy.dart` enforces this as an allow-list, with tests.
- **Don't wake or keep the car awake.** A permanently plugged-in adapter must stay quiet on the CAN bus while the car is off. `ATRV` reads the adapter's own supply pin and sends nothing on the bus: 12.8 V or more means the DC-DC converter is running (car on or charging), anything lower means off. Only poll while it reads ≥ 12.8 V, and re-check at least every 90 s (`transport/bus_gate.dart`). We measured 13.8–14.1 V with the car on, but also 12.9 V for a whole drive (2026-10-11). Strait also treats driving (≥ 10 km/h by the car's own speed reading, within the last 2 minutes) as on.
- **Rate.** Leave at least about 85 ms between bus requests (≈12 per second at most).

## 2. Adapter and connection
**Bluetooth.** ELM327 BLE adapters expose a UART-like GATT service: one characteristic to write commands to, one to get notifications from. UUIDs differ between adapters (common ones are FFF0/FFF1/FFF2, FFE0/FFE1 and 18F0/2AF0/2AF1), so the app picks the first service that has both a notify and a write characteristic, preferring FFF0, FFE0 and 18F0 (`transport/ble_uart_link.dart`). The vLinker FD+'s exact UUIDs are shown on the app's Car tab ("BLE link") and are *to be recorded here*. Commands are ASCII ending in `\r`, and a reply is complete when the `>` prompt arrives. Writes are chunked to 20 bytes.

**Setup sequence** (all adapter-local, nothing on the bus):

| Command | Reply seen | Purpose |
|---|---|---|
| `ATZ` | `ELM327 v2.2` | reset |
| `ATE0` | `ATE0` / `OK` | echo off (the reply still echoes, because echo was on when it arrived) |
| `ATL0` | `OK` | no linefeeds |
| `ATS0` | `OK` | no spaces |
| `ATH1` | `OK` | headers on: every frame is printed with its CAN ID and ISO-TP PCI byte |
| `ATSP6` | `OK` | ISO 15765-4 CAN, 11-bit IDs, 500 kbps |
| `ATFCSD300000` | `OK` | flow-control frame: clear to send, no block limit, no separation time |
| `ATI` | `ELM327 v2.2` | identification |
| `ATRV` | `13.8V` | supply voltage (car on) |

**Addressing a module:** `ATSH<tx>` (request ID), `ATFCSH<tx>` (flow-control ID), `ATCRA<rx>` (only show replies from `rx`), and `ATFCSM1` once, to use the user-defined flow control. Resend only when the module changes. For the functional address 7DF: `ATSH7DF`, `ATAR`, `ATFCSM0`.

**Reply format** with `ATH1` + `ATS0`: one line per CAN frame, `<3 hex ID><PCI><data>`, for example `7E9056220500280`. That's ID 7E9, a single frame of 5 bytes, `62 2050 0280` (SOC 64.0 %). Single frames arrive without padding bytes. Multi-frame replies show first frame and consecutive frames with their PCI bytes, and the app reassembles them itself. The VIN reply (`22F190`) is three frames: `10 14 62 F1 90 …`, `21 …`, `22 …`. Status words include `NO DATA`, `CAN ERROR`, `BUFFER FULL`, `?` and `<DATA ERROR`.

## 3. The bus and its modules
The OBD port reaches these modules. Each replies on its request ID + 8 (11-bit IDs):

| Module | Request / reply | Supplier (F18A) | Software (F195) | What it has |
|---|---|---|---|---|
| BMS | 7E1 / 7E9 | CATL | BMSN39021 | SOC, pack voltage and current, cell voltages, temperatures, counters |
| VCU | 7C2 / 7CA | Magna Electronics | VCU039023 | VIN, speed, 12 V, identification only in the swept ranges |
| BCM | 7C1 / 7C9 | (00000431031) | BCM395042 | odometer, door locks, tyre pressures |
| MCU_F | 786 / 78E | Magna MPT | MCU5000021 | front motor controller; identification only in the swept ranges |
| MCU_R | 7F2 / 7FA | Magna MPT | MCU5000021 | rear motor controller; identification only in the swept ranges |
| OHC | 783 / 78B | Magna | OHC390008 | on-board charger; identification only in the swept ranges |
| PDU | 7F3 / 7FB | Inovance | PDU3900D02 | power distribution; identification only in the swept ranges |
| ESP | 7D0 / 7D8 | Bosch | 89819V050101060131 | wheel speeds (FD00) and other FDxx data |
| ECC | 7F0 / 7F8 | (V01990) | ECC395 25 | climate; identification only in the swept ranges |

- **Functional address 7DF (standard OBD-II):** no answer to any mode `01` PID (`0100`, `010D`, `015B` and 16 others). The Ocean has no legislated OBD data on this port; everything comes from UDS `0x22` on each module.
- **No usable broadcast traffic.** A 5 s passive listen (`ATMA`) saw a single frame repeated with `<DATA ERROR` until `BUFFER FULL`. The port is behind a gateway, so every value has to be polled.
- **`EFxx` DIDs are live values on every module**, not identification: `EFF6` a clock, `EFF7` vehicle speed, `EFF8` odometer and `EFF9` the module's 12 V supply. The BMS is the exception for `EFF7`/`EFF8`: its `EFF7` doesn't track speed and its `EFF8` read `00000000` in the sweep, with only the last byte changing while driving. `F1xx` are the ISO 14229 identification DIDs (part numbers, software, VIN) and are constant.
- **Negative responses seen:** `requestOutOfRange` (0x31) for DIDs that don't exist, which is the normal answer during a sweep. ESP returned `generalReject` (0x10) for 15 DIDs in `FDxx` (listed in the catalog); they may need a session change, which we don't do.
- **Sweep coverage:** 2,304 DIDs per module in `2000–21FF`, `3400–34FF`, `D000–D1FF`, `EF00–EFFF`, `F100–F1FF`, `F400–F4FF` and `FD00–FDFF`. 272 DIDs returned data. `D0xx`, `D1xx` and `F4xx` returned nothing on any module.

## 4. Decoded signals
Values are big-endian; "data" is the bytes after the `62 <DID>` echo. **Verified** means checked on the car (against the dash, GPS or an energy balance), and each row gives the evidence.

| Signal | Module / DID | Decoding (metric) | Evidence |
|---|---|---|---|
| VIN | VCU F190 (also BMS, BCM, PDU, ESP, ECC) | 17 ASCII bytes | matches the car |
| Odometer | BCM 3409 | uint32 ÷ 100 = km (0.1 km steps in practice) | matches the dash; tracks GPS distance within 3 % over 22 km |
| Odometer (copy) | EFF8 on every module except BMS | uint32 ÷ 100 = km | same value as BCM 3409 |
| HV state of charge | BMS 2050 | uint16 ÷ 10 = % | matched the dash (64.0 % vs 64); later read 1.1 above the dash, see §5 |
| 12 V supply | VCU EFF9 (EFF9 on every module) | uint16 ÷ 1000 = V | ≈14.1 V with the car on |
| Vehicle speed | VCU EFF7 (EFF7 on every module except BMS) | uint16 ÷ 10 = km/h | r = 0.999 against GPS speed; reads ≈3 % below GPS, the same gap as odometer vs GPS distance |
| HV pack current | BMS 2004 | data bytes 2–3, uint16 ÷ 10 − 2000 = A; positive = discharging | over a 32 min drive, V × I integrates to 5.75 kWh vs 5.54 kWh from the SOC drop (at 113 kWh) |
| HV pack voltage | BMS 2107 (2109, 2117 agree within 1 V) | uint16 ÷ 10 = V | 391–413 V, sags under load; ≈102 × average cell voltage |
| HV power | computed | voltage × current ÷ 1000 = kW | from the two above; confirmed in ABRP |

These are the signals the ABRP app sends (SOC, speed, power, voltage, current, odometer), and ABRP showed them live on 2026-09-29.

## 5. Candidates and observations
Seen in recordings but not confirmed. The catalog marks these "(observed)" or "(candidate)".

| What | Module / DID | Observation |
|---|---|---|
| Other SOC values | BMS 2047, 2048, 2049 | uint16 ÷ 10 %; sit 1.2–2.4 points below 2050 and move with it (max/min/average cell SOC?). At a dash reading of 74 %: 2050 = 75.1, 2047 = 73.9, 2049 = 73.3, 2048 = 72.6. Which one the dash shows is open. |
| Cell voltages | BMS 2136, 2137, 2138 | uint16 ÷ 1000 V, 3.84–4.04 V; look like min/max/average |
| Battery temperature | BMS 2089–2094 | uint16 ÷ 100 = 22.1–22.3 °C on two days, all six agree within 0.2; plausible for a thermally managed pack, not confirmed |
| Rising temperatures? | BMS 2031, 2033 (and 2032/2034 bytes 0–1) | 0x8F → 0xA0 and 0x9A → 0xB0, rising steadily through a drive |
| Drive current | BMS 2016 | int32 × 0.1 A, tracks 2004 but reads 0 at idle when 2004 shows ≈7 A (no auxiliaries?) |
| Smooth pack voltage | BMS 2003 bytes 0–1 | ÷ 10 = 400–411 V, less sag than 2107 |
| Energy counters? | BMS 2144, 2145 (bytes 1–2) | rose by 70 and 67 over a drive that used ≈5.5 kWh |
| Powertrain state | BMS 2061 | 01 parked in Ready, 05 while driving |
| Power limits? | BMS 2063, 2064 | 829–3238 and 0–738, vary a lot |
| Tyre pressures | BCM 3427, 4 × uint8 | zero until the TPMS sensors wake (≈20 min of driving), then C1 C1 C3 C2. At 0.2 psi/bit that's 38.6–39.0 psi; the scale and wheel order need the dash. BCM 3428 (3 bytes) woke at the same moment. |
| Door locks | BCM 3403, 3404 | changed when the doors locked after pulling away |
| Wheel speeds | ESP FD00, 4 × uint16 | ≈0.0288 km/h per bit (r = 1.00 against GPS) |

## 6. What didn't work or isn't there
- **OBD-II mode 01** on 7DF: no answer at all.
- **Passive listening** (`ATMA`): only `<DATA ERROR` frames. Don't bother.
- **Gear / P-R-N-D:** nothing in the swept ranges changed only when reversing. Parked can be inferred (speed 0 for 60 s).
- **Charging state (AC/DC), outside temperature, cabin temperature, HVAC power, SOH, range:** not found in the swept ranges. Charging can be inferred from pack current below −5 A while stationary, and DC from more than 12 kW (the on-board charger tops out at 11 kW).
- **VCU, motor controllers, charger, PDU, climate:** only `EFxx`/`F1xx` answered in the ranges swept. Their live data is in other DID ranges.

## 7. Timing and throughput
- One adapter round trip (command → `>`) takes ≈50–60 ms over BLE.
- Switching modules costs three extra round trips (`ATSH`, `ATFCSH`, `ATCRA`), so read one module's DIDs back to back. Interleaving modules on every read gave ≈4.4 reads/s; mostly grouped gave ≈5.4/s. Fully grouped at the 85 ms rate cap should approach 11/s.
- The full sweep (9 modules × 2,304 DIDs, mostly NRC 0x31 answers) took about 30 minutes.
- The ABRP link polls SOC, speed, current and voltage once a second and the odometer once a minute. That's ≈5 reads/s across 3 modules.

## 8. Open questions
1. **Charging DIDs:** record AC and DC charging sessions and run `tools/analyze/analyze.py`. Look at BMS 2041/2042/2061/2062 and the state-like DIDs.
2. **Which SOC the dash shows:** compare 2050 and 2047–2049 with the dash at several charge levels.
3. **Tyre pressure scale and wheel order:** read the four dash values next to BCM 3427.
4. **Gear:** a stationary P → D → N → R → P test while recording; if nothing follows it, sweep the VCU over 0x0000–0xFFFF (≈1.5 h at the rate cap).
5. **Live data on VCU, MCU, OHC, PDU and ECC:** wider sweeps (for example `0100–1FFF`, `2200–33FF`, `3500–CFFF`, `D200–EEFF`, `F200–FCFF`). A full 64 K sweep per module is feasible because the sweep resumes.
6. **BLE UUIDs of the vLinker FD+:** record them in §2.

## 9. How to reproduce or extend this
1. Install **Ocean Discovery** (`discovery/`) and connect to the adapter on its Connect tab.
2. **Discover:** run the sweep while parked in Ready. Progress is saved, so it can span several sittings. Edit `defaultSweepRanges` in `discovery/lib/discovery/discovery_sweep.dart` for other ranges.
3. **Record:** drive or charge, then fill in the stop checklist. The session polls every DID that answered (bundled list plus any local sweep).
4. **Sessions:** share the JSONL and copy it into `data/sessions/` (git-ignored: it contains the VIN and GPS).
5. **Analyse:** `python3 tools/analyze/analyze.py` reports which DIDs track GPS speed and tractive power, does an energy check, and lists state-like DIDs.
6. **Publish:**
   - add confirmed signals to `ocean.json` with an `evidence` note;
   - regenerate the bundled DID list with `tools/analyze/export_did_list.py`;
   - regenerate this catalog with `tools/analyze/catalog.py <discovery.json> <sessions…>`.

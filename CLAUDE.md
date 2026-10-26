# CLAUDE.md

Guidance for working in this repository.

## What this is

HouseBridge is a native macOS (15+) menu bar app and CLI, written in Swift 6 with no third-party packages and no VM. It does two jobs:

1. **Rule engine.** Lutron Caseta Pico remotes/switches and UniFi Protect cameras/sensors trigger Philips Hue lights, scenes and rooms. All behavior lives in one YAML file (`~/.config/housebridge/config.yaml`, or `$HOUSEBRIDGE_HOME`).
2. **HomeKit bridge (for UniFi Protect).** Publishes Protect motion, contact, leak and doorbell sensors to Apple Home so it can replace Homebridge's UniFi Protect plugin. No video.

README.md is the user-facing doc; this file is for working on the code.

## Commands

```sh
swift build --disable-sandbox              # debug build: housebridgectl + HouseBridgeMenu
swift build -c release --disable-sandbox   # release build (SRP math is ~50x faster than debug)
swift test --disable-sandbox               # all tests; ~60 s, almost all of it SRP bignum math in a debug build
swift test --disable-sandbox --filter HAPProtocolTests   # one suite
./scripts/bundle.sh                        # universal HouseBridge.app (+ .zip)
```

Always pass `--disable-sandbox` to `swift build`/`swift test`.

CLI (`housebridgectl`): `init`, `validate`, `run [--dry-run]`, `events`, `devices`, `list lutron|hue|unifi`, `diagnose`, `logs`, `pair-hue`, `set-unifi-password`, `homekit [--reset]`, `import-homebridge`. Global `--config <path>` picks another config file.

Use `HOUSEBRIDGE_HOME=/tmp/somewhere` to run the CLI against an isolated config/state directory when experimenting.

## Layout

- `Sources/HouseBridgeCore/` – everything that matters
  - `Config.swift`, `YAML.swift` – hand-written YAML subset parser and config validation (`ConfigLoader`)
  - `Hub.swift` – wires sources (Lutron, UniFi, HomeKit) to the rule engine and Hue; one Hub per loaded config
  - `RuleEngine.swift`, `Events.swift` – `TriggerEvent` (has an optional `deviceID`, the Protect id), gesture timing, cooldowns
  - `Schedule.swift` – `when: { at: … }` rules: `Sun` (NOAA sunrise/sunset), `Schedule` (clock/sunrise/sunset + offset + weekdays), `ClockScheduler` (polls the wall clock every 10 s and emits `Source.clock` events; skips times >5 min late after Mac sleep). Needs `location:` for sun times. Sun math was cross-checked against an independent Meeus bisection, not just published tables
  - `Presence.swift` – `presence:` holds ("someone is home"): sensor triggers pause automatic rules (non-Pico) that act on listed devices for `hold_hours`, sliding; `RuleEngine` keeps `holdUntil`, persists it via `HoldStore` (`holds.json`), cancels pending Lutron off-timers when a hold starts, and on expiry `reconcile` runs, per device, the latest `at:` rule due (`Schedule.previous`) plus any `on_resume` rules
  - `Lutron/`, `Hue/`, `UniFi/` – device clients. `UniFi/ProtectClient.swift` logs in, reads the bootstrap, follows the update websocket; `ProtectPacket.swift` decodes packets and `ProtectInterpreter` turns them into events
  - `HAP/` – the HomeKit bridge (see below)
  - `Import/` – Homebridge importer (see below)
  - `Keychain.swift`, `TLS.swift` (trust-on-first-use pinning), `Diagnostics.swift`, `Catalog.swift`, `Paths.swift`
- `Sources/housebridgectl/main.swift` – CLI
- `Sources/HouseBridgeMenu/` – SwiftUI menu bar app (shows a QR code and setup code until HomeKit is paired)
- `Tests/HouseBridgeCoreTests/` – XCTest

`Subsystem` is `lutron, hue, unifi, homekit`; the menu app and `Catalog` iterate `allCases`.

## HomeKit bridge (`Sources/HouseBridgeCore/HAP/`)

A from-scratch HomeKit Accessory Protocol (HAP) server. CryptoKit supplies Curve25519, Ed25519, HKDF-SHA512 and ChaCha20-Poly1305; everything else is ours.

| File | Role |
|---|---|
| `BigUInt.swift` | Minimal unsigned bignum + Montgomery modular arithmetic (no long division needed) |
| `SRPGroup.swift` | The RFC 5054 3072-bit prime (= RFC 3526 group 15). Generated and primality-checked from its π-based definition, not typed from memory; do not hand-edit |
| `SRP.swift` | SRP-6a (SHA-512, user `Pair-Setup`), server and a test-only client |
| `TLV8.swift`, `HAPCrypto.swift` | TLV8 codec; HKDF/ChaCha helpers and nonce builders |
| `HAPStore.swift` | Identity + pairings persisted in `homekit.json` (0600): device id, Ed25519 key, setup code, setup id, config number `c#`, pairings, stable accessory ids, cached device list. Only writes when something changed |
| `HAPAccessories.swift` | Accessory/service/characteristic model, `HAPLayout.build` (Protect device -> HomeKit services), layout fingerprint for `c#` |
| `HAPServer.swift` | Protocol core with no sockets: `HAPServer` (database, values, events, pairings) and `HAPConnection` (pair-setup, pair-verify, encrypted framing, `/accessories`, `/characteristics`, `/pairings`, EVENT notifications) |
| `HAPListener.swift` | `NWListener` + Bonjour `_hap._tcp` advertisement; feeds bytes to `HAPConnection` |
| `HomeKitBridge.swift` | Public façade used by `Hub`: lifecycle, single-instance `flock`, inventory -> accessories, Protect events -> characteristic updates |

Mapping: camera `motion` -> MotionSensor; `ring` -> StatelessProgrammableSwitch (single press event); sensor `contact` -> ContactSensor (1 = open); `motion` -> MotionSensor; `leak` -> LeakSensor; with `smart_detections: true`, each smart-detect type -> an extra MotionSensor. Bridge is aid 1; each Protect device gets a permanent aid.

Wiring: `ProtectClient` takes `onInventory:` (called after every bootstrap, items carry initial `state`); `Hub` tees raw Protect events to `HomeKitBridge.handle` as well as the rule engine. In `--dry-run`/`events` modes the HomeKit bridge is not started. Only one process may own the bridge (`homekit.lock`); `Hub.stop()` releases it synchronously so a config reload can restart it.

Config (`homekit:` section): `name`, `port`, `setup_code` (validated; HomeKit rejects trivial codes), `smart_detections`. It requires a `unifi:` section.

### What is and is not verified

- Verified by tests: bignum against Python `pow()` vectors, Fermat on the group prime, SRP client/server round trip, TLV8, and the whole pairing/session/event flow against an in-process "controller" in `HAPProtocolTests`.
- **Not verified:** pairing with a real iPhone/Home.app, and the network layer (`HAPListener`, Bonjour). The controller in the tests is written from the same reading of the HAP spec as the server, so it proves self-consistency, not interoperability. The agent sandbox blocks opening listening sockets (`EPERM`), so the listener could not be run there; test live outside the sandbox on a real LAN.
- Known ambiguity: the SRP session key hashes the unpadded `S`; about 1 in 256 pairing attempts may fail on a leading-zero mismatch. Retrying works.
- Pairing requires the iPhone/Mac to be on the same LAN/VLAN as the bridge (Bonjour + direct TCP). It cannot be done remotely, and Home Assistant cannot either. Options: use Home.app on a Mac on that LAN, or have an edit-capable Home member pair at the house. If pairing times out, check `housebridgectl logs` (look for `pair setup started`), `dns-sd -B _hap._tcp`, the macOS firewall prompt, Local Network permission and VLAN isolation.

## Homebridge importer (`Sources/HouseBridgeCore/Import/`)

`housebridgectl import-homebridge` moves the UniFi Protect settings from a running Homebridge into the HouseBridge config.

- Finds Homebridge via Bonjour (`BonjourDiscovery`), probes the Config UI X web UI on port 8581 (`HomebridgeUIClient`: `/api/auth/settings`, `/api/auth/login` or `/noauth`, `/api/config-editor`, `/api/accessories`), or reads a file (`--from-file`) or a given `--ui` URL. Bonjour alone only reveals name/IP/port; what a bridge exposes cannot be read without pairing.
- `HomebridgeImport.parse` extracts the Protect controller (`address`, `username`, `password`) and reports everything it cannot carry over (other plugins/accessories, plugin options, Home.app automations and names). The Config UI X platform (`config`) is ignored.
- **It never overwrites a config.** `ConfigAppend.apply`: no file -> create; file exists -> append only the missing top-level `unifi:`/`homekit:` sections after verifying the existing file loads, the merged file parses and validates, and every existing section is unchanged; keeps a `config.yaml.bak-<timestamp>` copy. Sections already present are left alone; if both exist it does nothing. An existing config that does not load is refused untouched. `--out` picks another file, `--print` only prints.
- The Homebridge password is never written to YAML; `--store-password` puts it in the Keychain, otherwise use `housebridgectl set-unifi-password`.
- The Bonjour discovery and web-UI download have not been run against a live Homebridge (sandbox); the Config UI X endpoints are from memory. `--from-file` is the reliable fallback and is covered by tests.

## Conventions and gotchas

- Match the surrounding code: terse comments that explain *why*, `// MARK:` sections, no new dependencies.
- Swift language mode is v5 (`Package.swift`); several classes are `@unchecked Sendable` and rely on a single serial queue. `HAPServer`/`HAPConnection` are not thread-safe: `HomeKitBridge` and `HAPListener` share one dispatch queue, and every call into the server must happen on it.
- Secrets: the UniFi password lives in the Keychain; `Diagnostics.sanitize` masks `password`, `token`, `app_key` and `setup_code`. Never log or write secrets to YAML.
- The YAML parser rejects duplicate keys and tabs; config sections are validated with `rejectUnknown`, so new keys must be added to the allowed lists in `Config.swift`.
- Existing tests construct `ProtectInterpreter.Device(id:name:kind:)` and `TriggerEvent`; keep new fields optional/defaulted.
- Nothing in the HomeKit or importer work has been committed yet unless `git log` says otherwise; check `git status` before assuming.

## HouseBridgePair (`Tools/HouseBridgePair/`, `scripts/build-pair.sh`)

macOS Home.app has no Add Accessory command. `HMAccessorySetupManager` (macOS 27+; HomeKit ships only in the iOSSupport/Catalyst SDK) can show the system sheet, so this is a tiny Mac Catalyst app built outside SwiftPM with `swiftc -target <arch>-apple-ios27.0-macabi`. Ad-hoc signed: the sheet asks for the setup code. `--use-payload --uri X-HM://…` needs the restricted `com.apple.developer.homekit.allow-setup-payload` entitlement (Developer account + profile; `build-pair.sh --sign … --profile …`).

- **Not verified:** it compiles and signs, but the agent sandbox cannot launch GUI apps, so `isSupported` and the pairing sheet have never been seen running. It must run on the same LAN as the bridge.

# HouseBridge

A native macOS menu bar app and CLI that turns Lutron Caseta Pico remotes and switches and UniFi Protect cameras and sensors into triggers for Philips Hue lights, scenes, and rooms. It can also publish the Protect motion, contact, leak and doorbell sensors to Apple Home as a HomeKit bridge, so it can replace Homebridge for that. It has no VM and no third-party packages. All behavior lives in one YAML file.

```yaml
rules:
  - name: Front porch on when a person is seen
    when: { unifi: Front Camera, event: person, state: start }
    between: ["18:00", "06:00"]
    then:
      - action: light
        room: Front Porch
        on: true
```

See [`config.yaml`](config.yaml) for a full example.

## Requirements

- macOS 15+
- Swift 6 toolchain (to build from source)
- A Lutron Caseta Smart Bridge, a Hue bridge, and/or a UniFi Protect console on your local network

## Install

```sh
swift build --disable-sandbox     # builds housebridgectl + the menu bar app
./scripts/bundle.sh               # builds a universal HouseBridge.app (+ .zip)
```

Run `swift test --disable-sandbox` for the unit tests.

## Setup

1. `housebridgectl init` creates `~/.config/housebridge/config.yaml`. Edit the device IPs.
2. **Hue:** `housebridgectl pair-hue`, then press the bridge's link button.
3. **Lutron:** put the three PEM files from LEAP pairing (CA, cert, key) in `lutron.certs_dir`, or name them with `ca:`, `cert:`, and `key:`.
4. **UniFi:** create a *local* user, set `unifi.username`, then run `housebridgectl set-unifi-password`. The password is stored in the macOS Keychain.
5. **HomeKit (optional):** add a `homekit:` section (see `config.yaml`), run `housebridgectl homekit` for the setup code, start HouseBridge, then in Home.app choose Add Accessory → More options and enter the code (the menu bar app also shows a QR code). Cameras and sensors appear as accessories of one bridge.
6. `housebridgectl list lutron|hue|unifi` shows the exact device names to use in rules.
7. `housebridgectl validate`, then `housebridgectl run --dry-run`, then `housebridgectl run`. The menu bar app reloads the config live.

## Rules

Each rule has a `when:` trigger and a list of `then:` actions.

| | Options |
|---|---|
| **Triggers** | `at` (a 24-hour time, `sunrise` or `sunset`; see below), `pico` (button + gesture: `tap`, `double_tap`, `hold`, …), `switch` (on/off), `unifi` (`motion`, `person`, `vehicle`, `package`, … with `start`/`clear`) |
| **Actions** | `light`, `toggle`, `scene`, `cycle_scenes`, `dim`, `wait`, `log` |
| **Per rule** | `between`, `cooldown_seconds`, `enabled` |

### Time of day and sunrise/sunset

```yaml
location: { latitude: 37.7749, longitude: -122.4194 }   # west of Greenwich is negative; only needed for sun times

rules:
  - name: Porch on before sunset
    when: { at: sunset, offset_minutes: -30 }
    then: [{ action: light, room: Front Porch, on: true, brightness: 80 }]

  - name: Porch off late
    when: { at: "23:30", days: [fri, sat] }
    then: [{ action: light, room: Front Porch, on: false }]

  - name: Garage light off at dawn
    when: { at: sunrise }
    then: [{ action: lutron, switch: Garage Wall Lights, on: false }]
```

`at` is `"HH:MM"` on a 24-hour clock in the Mac's time zone, or `sunrise` / `sunset`; `offset_minutes` (negative = before) shifts the sun times, and `days` limits it (`mon`…`sun`, `weekdays`, `weekends`). Quote clock times. `between` and `cooldown_seconds` work as usual. Sun times are calculated locally from `location:` (accurate to about a minute). If the Mac is asleep through a scheduled time it is skipped when more than 5 minutes late, so waking at midnight does not run the sunset rule. `housebridgectl schedule` shows today's sunrise/sunset and each rule's next run.

### Pausing automation while someone is home

```yaml
presence:
  - name: Someone is home
    hold_hours: 24                 # or hold_minutes; default 24 hours
    when:                          # any of these starts (or renews) the hold
      - { unifi: Front Door Motion, event: motion, state: start }
      - { unifi: UP Sense GarageDoor, event: contact, state: open }
    pauses:                        # devices, named as in your rules
      - lutron: Garage Wall Lights
      - light: Hue outdoor wall 1  # also room: / zone:
```

While a hold is active, rules triggered by a sensor, the clock or a Lutron switch that act on a listed device are skipped (logged as "paused by …"), so people can use those lights by hand. Pico button presses are never paused, and a rule with `ignore_presence: true` keeps running during a hold. Every new trigger restarts the clock, so the hold ends only after a full `hold_hours` with no trigger; automation then resumes on its own. A pending `off_after_seconds` on a paused Lutron switch is cancelled when the hold starts. The end time is saved in `holds.json`, so reloads and restarts don't cut a hold short. `housebridgectl presence` shows what is paused and until when. **When a hold ends**, each paused device is put where the schedule would have it right now: for every listed device, the most recent time-of-day (`at:`) rule that targets it, respecting `days` and `between`, is run once. For example, if the hold ends at 9pm and the rules are sunset → on, 23:00 → off, sunrise → off, the light turns on; at 2am it turns off. Add `on_resume: true` to any other rule (say, one that turns a Lutron switch back on whenever it is switched off) to run it too at that moment. Sensor-triggered rules are not replayed; they act on the next event. If HouseBridge was not running when a hold ended, this happens at the next start.

Run `housebridgectl devices` for a catalog of what each device reports, what it can do, and example rules to paste in.

## HomeKit bridge

`homekit:` makes HouseBridge a HomeKit bridge for UniFi Protect, driven by the same connection the rules use:

| Protect | In Home.app |
|---|---|
| Camera motion | Motion sensor (plus one per smart detection with `smart_detections: true`) |
| Doorbell ring | Programmable switch (single press) |
| Door/window/garage sensor | Contact sensor, motion sensor |
| Leak sensor | Leak sensor |

There is no video or camera feed. Pairing identity and controllers are stored in `~/.config/housebridge/homekit.json`; deleting it (or `housebridgectl homekit --reset`) means pairing again. Only one HouseBridge process can run the bridge at a time. To move from Homebridge: remove the Protect accessories from Home.app, stop Homebridge, pair HouseBridge, then rebuild any Home automations that used the old accessories.

### Importing from Homebridge

`housebridgectl import-homebridge` reads a running Homebridge's `config.json` and writes the `unifi:` and `homekit:` sections for you. With no options it looks for HomeKit bridges over Bonjour, finds the one whose web UI (Homebridge Config UI X) answers on port 8581, asks for the UI login, and downloads the config through the UI's API. If that doesn't work, point it at the UI with `--ui http://<vm>:8581`, or copy `config.json` off the machine and use `--from-file`.

```sh
housebridgectl import-homebridge --store-password
```

It carries over the UniFi controller address and username. The password goes to the Keychain only with `--store-password`, never into the YAML. It lists what it could not carry over: Home.app automations, rooms and renamed accessories, other plugins, and the Protect plugin's feature options. Homebridge's Bonjour advertisement only reveals that a bridge exists and where it is; what it exposes can't be read without being paired to it, which is why the config comes from the UI. It never overwrites your config: if one exists, it appends only the `unifi:`/`homekit:` sections that are missing (leaving any you already have untouched), checks that the merged file parses and validates before writing, and keeps a timestamped `.bak-` copy of the original. If there is no config yet it creates one. `--out <file>` targets another file and `--print` just prints the YAML.

## Troubleshooting

- `housebridgectl events` shows live input.
- `housebridgectl logs` shows the log tail (`~/.config/housebridge/logs/`).
- `housebridgectl diagnose` prints a sanitized report with live connection tests. The menu bar app has a **Copy Diagnostics** button.

## Status

The YAML parser, config validation, gesture timing, rule engine, and Protect packet decoding are unit-tested. The HomeKit pairing and session protocol is tested against an in-process controller written from the HAP spec (SRP checked against Python big-integer reference values), not against a real iPhone. The Lutron LEAP session, Hue calls, the Protect websocket, and the HomeKit bridge have not yet been exercised against real hardware.

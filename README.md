# HouseBridge

A native macOS menu bar app and CLI that turns Lutron Caseta Pico remotes and switches and UniFi Protect cameras and sensors into triggers for Philips Hue lights, scenes, and rooms. It has no VM and no third-party packages. All behavior lives in one YAML file.

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
5. `housebridgectl list lutron|hue|unifi` shows the exact device names to use in rules.
6. `housebridgectl validate`, then `housebridgectl run --dry-run`, then `housebridgectl run`. The menu bar app reloads the config live.

## Rules

Each rule has a `when:` trigger and a list of `then:` actions.

| | Options |
|---|---|
| **Triggers** | `pico` (button + gesture: `tap`, `double_tap`, `hold`, …), `switch` (on/off), `unifi` (`motion`, `person`, `vehicle`, `package`, … with `start`/`clear`) |
| **Actions** | `light`, `toggle`, `scene`, `cycle_scenes`, `dim`, `wait`, `log` |
| **Per rule** | `between`, `cooldown_seconds`, `enabled` |

Run `housebridgectl devices` for a catalog of what each device reports, what it can do, and example rules to paste in.

## Troubleshooting

- `housebridgectl events` shows live input.
- `housebridgectl logs` shows the log tail (`~/.config/housebridge/logs/`).
- `housebridgectl diagnose` prints a sanitized report with live connection tests. The menu bar app has a **Copy Diagnostics** button.

## Status

The YAML parser, config validation, gesture timing, rule engine, and Protect packet decoding are unit-tested. The Lutron LEAP session, Hue calls, and Protect websocket have not yet been exercised against real hardware.

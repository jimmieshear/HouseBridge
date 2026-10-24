import Foundation

public let exampleConfig = """
# HouseBridge configuration. Edit this file; the menu bar app reloads it when it changes.
# Check it with:  housebridgectl validate

lutron:
  host: 192.168.1.50                      # Caseta Smart Bridge IP
  # PEM files from Lutron pairing. Either point at one folder (files are recognised by name:
  # *-ca.pem, *-cert.pem, *-key.pem as saved by Home Assistant) ...
  certs_dir: ~/lutron-certs
  # ... or name each file explicitly (these override certs_dir). Relative paths are resolved
  # against the folder that contains this config file.
  # ca:   /path/to/lutron_caseta-XXXX-ca.pem
  # cert: /path/to/lutron_caseta-XXXX-cert.pem
  # key:  /path/to/lutron_caseta-XXXX-key.pem

hue:
  host: 192.168.1.60                      # Hue bridge IP; then run: housebridgectl pair-hue

unifi:
  host: 192.168.1.1                        # UniFi OS console IP
  username: housebridge                    # a *local* account, not your Ubiquiti SSO login
  # Password lookup order: 'password:' here, then the env var named by 'password_env:', then the macOS Keychain.
  # Recommended: leave both out and run:  housebridgectl set-unifi-password
  # password_env: UNIFI_PASSWORD
  clear_after_seconds: 45                 # how long after motion stops before a 'clear' event

# Publish the UniFi Protect cameras and sensors to Apple Home (motion, contact, leak, doorbell), replacing
# Homebridge's UniFi Protect plugin for those. No video. Uncomment, then run:  housebridgectl homekit
# homekit:
#   name: HouseBridge                     # how the bridge appears in Home.app
#   # setup_code: 031-45-154              # optional; otherwise one is generated and remembered
#   # port: 51826                         # optional; default lets the system choose
#   # smart_detections: true              # also a motion sensor each for person, vehicle, animal, ...

timing:
  double_tap_ms: 300
  hold_ms: 500

# Find names with:  housebridgectl list lutron | hue | unifi
# Watch live events with:  housebridgectl events
rules:
  - name: Family room on
    when: { pico: Family Room Pico, button: on, gesture: tap }
    then:
      - action: light
        room: Family Room
        on: true
        brightness: 100

  - name: Family room off
    when: { pico: Family Room Pico, button: off, gesture: tap }
    then:
      - action: light
        room: Family Room
        on: false

  - name: Family room read scene
    when: { pico: Family Room Pico, button: on, gesture: double_tap }
    then:
      - action: scene
        room: Family Room
        name: Read

  - name: Family room brighter while held
    when: { pico: Family Room Pico, button: raise, gesture: hold }
    then:
      - action: dim
        room: Family Room
        direction: up
        step: 10
        repeat_while_held: true

  - name: Front porch on when a person is seen
    when:
      unifi: Front Camera
      event: person
      state: start
    between: ["18:00", "06:00"]
    cooldown_seconds: 30
    then:
      - action: light
        room: Front Porch
        on: true
        brightness: 100

  - name: Front porch off after things go quiet
    when:
      unifi: Front Camera
      event: person
      state: clear
    then:
      - action: light
        room: Front Porch
        on: false
        transition_ms: 4000
"""

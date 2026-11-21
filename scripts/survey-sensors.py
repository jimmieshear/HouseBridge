#!/usr/bin/env python3
"""Read-only survey of the sensors a house offers, from the two places HouseBridge can get them.

Run on the Mac that runs that house's HouseBridge (for Bend: the Bend Mac):

    python3 -I scripts/survey-sensors.py [--config PATH] [--helper PATH] [--out DIR]

  1. UniFi Protect, directly: logs in the way HouseBridge does (host and username from the config's `unifi:` section,
     password from the config, its `password_env`, or the Keychain item `housebridge.unifi`) and reads the bootstrap:
     every Protect sensor with its readings (`stats`: temperature, humidity, light ...), battery, mount type, leak/contact
     state, plus any other device type that is present. This is where UniFi environmental sensors really are; Homebridge
     and Home.app only show part of what Protect has.
  2. HomeKit, through the HouseBridgeHomeKit helper inside HouseBridge.app (`--list`): every sensor in every home Home.app
     shows this Mac, with its value and whether HouseBridge already forwards it.

It writes DIR/sensor-survey.txt (the summary below) and DIR/sensor-survey.json (details, secret-looking fields masked) and
prints the summary. Nothing is written to any device or to your HouseBridge config.

Uses only the Python standard library. Local consoles have self-signed certificates, so TLS is not verified (only the
address from your own config is contacted).
"""
import argparse, json, os, re, ssl, subprocess, sys, urllib.request
from http.cookiejar import CookieJar

SECRET = re.compile(r"pass|token|secret|key|mac$|rtsp|authUser|credential|cookie|serial|uid$|^ip$|host|wifi|ssid|email|phone|lat$|lng$|lon$|location", re.I)


def redact(o):
    if isinstance(o, dict):
        return {k: ("***" if SECRET.search(k) and not isinstance(v, (dict, list)) else redact(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [redact(x) for x in o]
    return o


def home_dir():
    return os.path.expanduser(os.environ.get("HOUSEBRIDGE_HOME") or "~/.config/housebridge")


def yaml_section(text, name):
    """Scalar children of the top-level `name:` block of the (simple) YAML config."""
    out, inside = {}, False
    for line in text.splitlines():
        if re.match(r"^\S", line):
            inside = line.startswith(name + ":")
            m = re.match(r"^" + name + r":\s*\{(.*)\}", line)   # one-line form: unifi: { host: x, username: y }
            if m:
                for part in m.group(1).split(","):
                    k, _, v = part.partition(":")
                    out[k.strip()] = v.strip().strip("\"'")
            continue
        m = re.match(r"^\s+([A-Za-z_]+):\s*([^#]*?)\s*(#.*)?$", line)
        if inside and m and m.group(2):
            out[m.group(1)] = m.group(2).strip("\"'")
    return out


def tls():
    c = ssl.create_default_context()
    c.check_hostname = False
    c.verify_mode = ssl.CERT_NONE
    return c


def fahrenheit(c):
    return c * 9 / 5 + 32


# ---------------------------------------------------------------------------------------------------- Protect

def protect(config_path, lines, raw, notes):
    try:
        text = open(config_path).read()
    except OSError as e:
        notes.append(f"Protect: cannot read {config_path} ({e}); skipped")
        return
    u = yaml_section(text, "unifi")
    host, user = u.get("host"), u.get("username")
    if not host or not user:
        notes.append("Protect: no unifi: host/username in the config; skipped")
        return
    pw = u.get("password") or os.environ.get(u.get("password_env", ""), "") or None
    if not pw:
        r = subprocess.run(["security", "find-generic-password", "-s", "housebridge.unifi", "-a", f"{user}@{host}", "-w"],
                           capture_output=True, text=True)
        pw = r.stdout.strip() if r.returncode == 0 else None
    if not pw:
        notes.append("Protect: password not found (config, env or Keychain); skipped")
        return
    jar = CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=tls()), urllib.request.HTTPCookieProcessor(jar))
    req = urllib.request.Request(f"https://{host}/api/auth/login",
                                 json.dumps({"username": user, "password": pw, "rememberMe": False}).encode(),
                                 {"Content-Type": "application/json"})
    try:
        op.open(req, timeout=20).read()
        boot = json.loads(op.open(f"https://{host}/proxy/protect/api/bootstrap", timeout=40).read())
    except Exception as e:
        notes.append(f"Protect: failed ({e})")
        return

    sensors = boot.get("sensors", [])
    lines.append("== UniFi Protect (direct) ==")
    lines.append(f"console {host}, {len(sensors)} sensor(s), {len(boot.get('cameras', []))} camera(s)")
    for s in sensors:
        stats = s.get("stats") or {}
        lines.append(f"\n  {s.get('name')}   [{s.get('marketName') or s.get('type')}]  mount={s.get('mountType')}  "
                     f"state={s.get('state')}  connected={s.get('isConnected', s.get('state') == 'CONNECTED')}")
        for key, v in stats.items():
            if isinstance(v, dict) and "value" in v:
                val = v["value"]
                extra = f"  (status: {v.get('status')})" if v.get("status") else ""
                if key == "temperature" and isinstance(val, (int, float)):
                    lines.append(f"      temperature: {val:.1f} °C = {fahrenheit(val):.1f} °F{extra}")
                else:
                    lines.append(f"      {key}: {val}{extra}")
            else:
                lines.append(f"      {key}: {json.dumps(v)}")
        bat = s.get("batteryStatus")
        if bat:
            lines.append(f"      battery: {bat.get('percentage')}%  low={bat.get('isLow')}")
        for flag in ("isOpened", "isMotionDetected", "leakDetectedAt", "externalLeakDetectedAt", "tamperingDetectedAt", "alarmTriggeredAt"):
            if flag in s:
                lines.append(f"      {flag}: {s[flag]}")
        enabled = [k for k, v in s.items() if k.endswith("Settings") and isinstance(v, dict) and v.get("isEnabled")]
        lines.append(f"      enabled features: {', '.join(enabled) or '(none)'}")
        lines.append(f"      all fields: {', '.join(sorted(s.keys()))}")

    kinds = {k: len(v) for k, v in boot.items() if isinstance(v, list) and v and k not in ("users", "groups", "liveviews", "ringtones", "cameras", "sensors")}
    if kinds:
        lines.append("\n  other Protect device types present: " + ", ".join(f"{k} ({n})" for k, n in kinds.items()))
    cams = [c for c in boot.get("cameras", []) if re.search(r"temp|humid|air|light", json.dumps(c.get("stats", {})), re.I)]
    for c in cams:
        keys = [k for k in (c.get("stats") or {}) if re.search(r"temp|humid|air|light", k, re.I)]
        if keys:
            lines.append(f"  camera '{c.get('name')}' reports: {', '.join(keys)}")
    raw["protect"] = {"sensors": redact(sensors), "other_device_types": {k: redact(boot[k]) for k in kinds}}


# ---------------------------------------------------------------------------------------------------- HomeKit

def homekit(helper, lines, raw, notes):
    candidates = [helper] if helper else [
        "/Applications/HouseBridge.app/Contents/Helpers/HouseBridgeHomeKit.app/Contents/MacOS/HouseBridgeHomeKit",
        os.path.expanduser("~/Applications/HouseBridge.app/Contents/Helpers/HouseBridgeHomeKit.app/Contents/MacOS/HouseBridgeHomeKit"),
        "HouseBridge.app/Contents/Helpers/HouseBridgeHomeKit.app/Contents/MacOS/HouseBridgeHomeKit",
    ]
    exe = next((c for c in candidates if c and os.path.exists(c)), None)
    if not exe:
        notes.append("HomeKit: HouseBridgeHomeKit helper not found (install the current HouseBridge.app, or pass --helper PATH); skipped")
        return
    try:
        r = subprocess.run([exe, "--list"], capture_output=True, text=True, timeout=150)
    except subprocess.TimeoutExpired:
        notes.append("HomeKit: --list timed out")
        return
    except OSError as e:
        notes.append(f"HomeKit: could not run the helper ({e})")
        return
    if r.returncode != 0 and not r.stdout.strip():
        notes.append(f"HomeKit: helper exited {r.returncode}: {(r.stderr or '').strip()[:300]}"
                     + ("  (a TCC / privacy crash means Terminal may not read Home; run it from HouseBridge instead)" if r.returncode in (-6, 134) else ""))
        return
    lines.append("\n== HomeKit (Home.app, every home on this Mac) ==")
    lines.append((r.stderr or "").strip().splitlines()[0] if r.stderr.strip() else "")
    lines.append(r.stdout.rstrip())
    raw["homekit"] = r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(home_dir(), "config.yaml"))
    ap.add_argument("--helper", help="path to the HouseBridgeHomeKit executable (default: inside /Applications/HouseBridge.app)")
    ap.add_argument("--out", default=os.path.expanduser("~/Desktop"))
    ap.add_argument("--skip-homekit", action="store_true")
    ap.add_argument("--skip-protect", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    lines, raw, notes = [], {}, []
    if not a.skip_protect:
        protect(a.config, lines, raw, notes)
    if not a.skip_homekit:
        homekit(a.helper, lines, raw, notes)
    if notes:
        lines.append("\n== Notes ==")
        lines += ["  " + n for n in notes]
    report = "\n".join(lines).strip() + "\n"
    txt, js = os.path.join(a.out, "sensor-survey.txt"), os.path.join(a.out, "sensor-survey.json")
    open(txt, "w").write(report)
    open(js, "w").write(json.dumps(raw, indent=2, default=str))
    print(report)
    print(f"Wrote {txt} and {js}. Send me the .txt contents (the .json has more detail, secrets masked).")


main()

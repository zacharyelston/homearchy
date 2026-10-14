#!/bin/bash
# Set up the ZHA (Zigbee) integration on the Home Assistant VM from this host, no browser needed.
#
#   bin/ha-zha-setup.sh [--dry-run]
#
# How it works: SSH into the Advanced SSH & Web Terminal add-on (key login, see
# docs/home-assistant.md) and drive Home Assistant's config-flow REST API through the Supervisor
# proxy, authenticating with the add-on's own $SUPERVISOR_TOKEN. No long-lived token is created
# or stored. Home Assistant auto-detects the radio, so no radio type or baud rate is needed.
#
# Idempotent: exits 0 if a ZHA entry already exists. --dry-run walks the flow up to the
# "choose setup strategy" menu, then aborts it without forming a network.
# Stops (and aborts the flow) on any step it does not recognise, printing that step. Forming the
# network takes a few seconds (a "progress" step); the script polls until it finishes.
#
# Prerequisites: the dongle is passed through to the VM (stage2, HAOS_USB_HOSTDEVS) and the
# add-on accepts your SSH key.
# Env: HA_SSH          ssh target (default zaq@homeassistant.local)
#      ZHA_SERIAL_MATCH  substring of the /dev/serial/by-id name to use (default SONOFF)
set -euo pipefail

HA_SSH=${HA_SSH:-zaq@homeassistant.local}
ZHA_SERIAL_MATCH=${ZHA_SERIAL_MATCH:-SONOFF}
dry=0
case "${1:-}" in
  --dry-run) dry=1 ;;
  "") ;;
  *) echo "usage: $0 [--dry-run]"; exit 64 ;;
esac

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HA_SSH" \
  "ZHA_DRY_RUN=$dry ZHA_SERIAL_MATCH=$(printf %q "$ZHA_SERIAL_MATCH") bash -lc 'python3 -'" <<'PY'
import glob, json, os, sys, time, urllib.request

API = "http://supervisor/core/api/config/config_entries"
H = {"Authorization": "Bearer " + os.environ["SUPERVISOR_TOKEN"], "Content-Type": "application/json"}
DRY = os.environ["ZHA_DRY_RUN"] == "1"
MATCH = os.environ["ZHA_SERIAL_MATCH"]
STRATEGY = "setup_strategy_recommended"


def call(method, url, body=None):
    req = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                                 headers=H, method=method)
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read() or b"{}")


entries = [e for e in call("GET", API + "/entry") if e["domain"] == "zha"]
if entries:
    print("ZHA already configured:", ", ".join(f"{e['title']} ({e['state']})" for e in entries))
    sys.exit(0)

ports = [p for p in sorted(glob.glob("/dev/serial/by-id/*")) if MATCH in p]
if len(ports) != 1:
    sys.exit(f"expected exactly one /dev/serial/by-id/*{MATCH}* in the VM, found {ports or 'none'} "
             "(dongle not passed through? several dongles? set ZHA_SERIAL_MATCH)")
print("serial port:", ports[0])

flow = call("POST", API + "/flow", {"handler": "zha", "show_advanced_options": False})
fid = flow["flow_id"]
done = False
try:
    step = flow
    for _ in range(8):
        kind, sid = step["type"], step.get("step_id")
        print(f"step: {kind} {sid or step.get('reason', '')}")
        if kind == "create_entry":
            print("created ZHA entry:", step.get("title"))
            done = True
            break
        if kind == "abort":
            sys.exit(f"flow aborted by Home Assistant: {step.get('reason')}")
        if kind == "form" and sid == "choose_serial_port":
            step = call("POST", f"{API}/flow/{fid}", {"path": ports[0]})
        elif kind == "progress":
            # The radio is busy (e.g. forming the network). Poll the flow until it moves on.
            for _ in range(60):
                time.sleep(2)
                step = call("GET", f"{API}/flow/{fid}")
                if step["type"] != "progress":
                    break
            else:
                sys.exit("timed out waiting for Home Assistant to finish step " + str(sid))
        elif kind == "menu" and sid == "choose_setup_strategy":
            if DRY:
                print("dry run: stopping before forming a network")
                break
            step = call("POST", f"{API}/flow/{fid}", {"next_step_id": STRATEGY})
        else:
            sys.exit("unrecognised step, flow aborted: " + json.dumps(
                {k: step.get(k) for k in ("type", "step_id", "menu_options", "errors", "description_placeholders")}))
    else:
        sys.exit("too many steps, aborting")
finally:
    if not done:
        try:
            call("DELETE", f"{API}/flow/{fid}")
        except Exception:
            pass

if done:
    now = [e for e in call("GET", API + "/entry") if e["domain"] == "zha"]
    print("verified:", ", ".join(f"{e['title']} ({e['state']})" for e in now) or "ZHA entry not found")
PY

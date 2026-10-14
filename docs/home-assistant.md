# Home Assistant post-install notes

Steps done after `stage2/setup.sh` creates the HAOS VM (libvirt guest
`homeassistant`, bridged on `br0`). Sections say whether they are automated by
stage 2 or still manual. No secrets belong in this file (public repo).

## Reach the UI
- `http://homeassistant.local/` (or `http://<VM LAN IP>/`). Home Assistant OS 18 serves the UI on port 80, not 8123; the Supervisor observer is on port 4357.
- VM control from the host: `virsh -c qemu:///system {list --all,reboot,start} homeassistant`

## Restart cheat sheet
- Core: Settings -> System -> power icon -> Restart Home Assistant, or `ha core restart`
- Add-on: Settings -> Add-ons -> <add-on> -> Restart, or `ha addons restart <slug>`
- Whole VM: `ha host reboot`, or `virsh ... reboot homeassistant`

## Advanced SSH & Web Terminal add-on
Install from the add-on store. It exits immediately (`FATAL: Configuration of
this app is incomplete`) until a credential is set. Options are nested under
`ssh:`:

```yaml
ssh:
  username: hassio
  password: ""
  authorized_keys:
    - "ssh-ed25519 AAAA... user@host"   # public key only
  sftp: false
  compatibility_mode: false
  allow_agent_forwarding: false
  allow_remote_port_forwarding: false
  allow_tcp_forwarding: false
```

- Prefer a key over a password (short or breached passwords are rejected).
- Keys must go in the add-on's `ssh.authorized_keys` option, then **restart the add-on**
  (options are only read at start). `ssh-copy-id` does not work: it reports success but the
  add-on builds its allowed keys from its options, so the login keeps asking for a password.
- Set `username` to your login (e.g. `zaq`); `bin/ha-zha-setup.sh` connects as
  `zaq@homeassistant.local` by default (override with `HA_SSH`).
- Non-interactive commands need a login shell so `ha` and `$SUPERVISOR_TOKEN` are set:
  `ssh zaq@homeassistant.local 'bash -lc "ha core info"'`.
- Through that token the add-on can call Home Assistant's REST API via the Supervisor proxy:
  `curl -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/core/api/config`.
  Scripts use this instead of a long-lived access token, so no secret is stored anywhere.
- Set a host port under Network (e.g. 22). Do not use 22222; HAOS's own SSH owns it.
- "Service not enabled" errors for mosquitto/mysql in the log are harmless.
- Connect: `ssh hassio@<ha-ip>`

## HACS
Run in the SSH add-on terminal (not on the host):

```bash
wget -O - https://get.hacs.xyz | bash -
```

`https://hacs.xyz` is the website, not the script; piping it to bash fails on
`<!doctype html>`. Then restart Core, hard-refresh the browser, and add the
HACS integration (Settings -> Devices & Services), authorizing via
github.com/login/device.

## Echo / Alexa devices
An Echo is a voice front end, not a device source. Add each light/switch with
the integration for its actual brand (Hue, Kasa, Tuya/Smart Life, Zigbee/ZHA,
etc.), then expose the entities back to Alexa via Home Assistant Cloud or the
Alexa smart home skill. The HACS "Alexa Media Player" integration only adds the
Echo speakers themselves (TTS, media control).

## Zigbee / Z-Wave dongle (USB passthrough)

Automated by stage 2 for the dongle, manual for the Home Assistant side.

Hardware in use (dev box): SONOFF Dongle Lite MG21, USB `10c4:ea60` (a CP210x
USB-serial bridge to a Silicon Labs EFR32MG21 running Zigbee coordinator (EZSP)
firmware). `10c4:ea60` is shared by other CP210x adapters; with two of them
plugged in, libvirt's vendor:product match is ambiguous.

**Host side (automated, `stage2/setup.sh`):**
- Adds the install user to `uucp`, the Arch group for `/dev/ttyUSB*` and
  `/dev/ttyACM*`. It takes effect at the next login (`id` shows it).
- Attaches every vendor:product listed in `HAOS_USB_HOSTDEVS` (`stage2/haos.env`)
  to the VM, live and in its saved config. Skipped if already attached or not
  plugged in; re-run stage 2 after plugging it in. `startupPolicy=optional`
  means the autostart VM still boots with the dongle unplugged. Manual
  equivalent: `virt-xml homeassistant --add-device --hostdev 10c4:ea60,source.startupPolicy=optional --update`.
- Do not add `--print-diff` to a `virt-xml ... --update` command expecting a dry
  run: it still hot-plugs the device into the running VM. Drop `--update` to
  preview.

**Test before passthrough:** `bin/zigbee-probe.sh` (`--list` shows IDs and serial
paths). It sends an EZSP reset and expects `1a c1 ... 7e` back at 115200 baud.
Once the VM owns the dongle the host loses `/dev/ttyUSB0`, so probe first; to
get the dongle back on the host, detach it:
`virsh detach-device homeassistant <hostdev.xml> --live --config`.

**Home Assistant side (automated, `bin/ha-zha-setup.sh`):** needs the SSH key login above.
It drives the ZHA config flow through the Supervisor API: picks the dongle's
`/dev/serial/by-id/*SONOFF*` path (override with `ZHA_SERIAL_MATCH`), accepts the
"recommended" setup strategy and waits while the radio forms a new network. Home Assistant
auto-detects the radio, so no radio type or baud is entered (it stores `ezsp`, 115200,
flow control none). Re-running is safe (exits if ZHA exists); `--dry-run` stops before forming
a network. Do not run it while ZHA is open in the browser. Verified on the dev box 2026-10-14:
entry `loaded`, `/config/zigbee.db` holds the coordinator and one network backup.

Manual equivalent: Settings -> Devices & services -> Add -> Zigbee Home Automation, pick the
SONOFF path, choose "recommended" setup. To pair a device afterwards: the ZHA entry -> Add
device, then put the device in pairing mode (usually hold its button 5-10 s).

To start over: delete the ZHA integration (Settings -> Devices & services -> ZHA -> Delete),
then re-run the script; the dongle forms a fresh network, so paired devices must be re-paired.

Zigbee shares 2.4 GHz with Wi-Fi and is sensitive to USB 3 noise: if pairing is flaky, put the
dongle on a short USB extension cable away from hubs.

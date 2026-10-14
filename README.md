# homearchy

Infrastructure-as-code for a small always-on box that is both an
[Omarchy](https://omarchy.org) Linux desktop and a Home Assistant hub.
Built for a Mac mini (Late 2014), works on any UEFI x86-64 machine.

One USB stick installs Omarchy unattended. One command afterwards turns the box
into a KVM host running [Home Assistant OS](https://www.home-assistant.io/installation/)
in a VM, bridged onto your LAN so phones and smart devices see it directly.

```
USB stick (Omarchy ISO + CIDATA partition)   -->   unattended Omarchy install, reboot
bin/provision.sh <host>   (or a one-liner at the console)   -->   libvirt + Home Assistant VM
```

## How it works

The stock Omarchy ISO supports unattended installs: if it finds a filesystem
labeled `CIDATA` it copies the installer's answers (`user_configuration.json`,
`user_credentials.json`, your SSH public key, ...) and runs without prompts.
`bin/make-usb.sh` writes the ISO to a stick and appends that partition, so a
single stick does everything. The ISO has no hook for extra packages, so the
Home Assistant part is a second stage that runs after first boot, over SSH or
from the console.

## Requirements

On the machine that builds the stick (an Omarchy/Arch box):

```
sudo omarchy-pkg-add mtools dosfstools gptfdisk gnupg python
```

On the target: wired Ethernet during install, Secure Boot off. Whole disk is wiped.

## Usage

1. **Configure**

   ```
   cp config.example.env config.env
   $EDITOR config.env
   ```

   Set the username, password, hostname, timezone, SSH public key, and the
   target disk and its exact size in bytes (`lsblk -bdno SIZE /dev/sda` on the
   target from any live USB, or from the spec sheet; the 256 GB Mac mini SSD is
   251000193024). `config.env` is gitignored.

2. **Build the payload and the stick**

   ```
   bin/make-cidata.sh
   sudo bin/make-usb.sh /dev/sdX        # the stick; everything on it is erased
   ```

   The ISO (6 GB) is downloaded once into `build/` and verified against its
   SHA-256 and the Omarchy signing key (`lib/omarchy.asc`).

3. **Install**

   Insert the stick. On a Mac mini, power on holding **Option**, pick the orange
   **EFI Boot** entry. The installer runs with no prompts and reboots into the
   installed system. The first login screen appears a few minutes later.

4. **Stage 2: Home Assistant**

   From any machine holding the matching SSH private key:

   ```
   bin/provision.sh <hostname-or-ip>
   ```

   Or at the box's own terminal, with network:

   ```
   curl -fsSL https://raw.githubusercontent.com/zacharyelston/homearchy/main/stage2/bootstrap.sh | bash
   ```

   Or offline, from the still-inserted stick:

   ```
   bash /run/media/$USER/CIDATA/stage2/bootstrap.sh --local
   ```

   Stage 2 installs qemu/libvirt, adds your user to the `libvirt` and `uucp`
   groups, bridges the wired NIC as `br0` (the host keeps its MAC and therefore
   its IP), opens ufw for VM traffic, downloads Home Assistant OS, creates the
   `homeassistant` VM (4 GB RAM, 2 vCPUs, 32 GB disk, autostart) and passes
   through the USB devices listed in `HAOS_USB_HOSTDEVS` (a Zigbee dongle). It prints the VM's LAN address; onboarding is at
   `http://<ip>/` or `http://homeassistant.local/` (Home Assistant OS 18 serves the UI on port 80; the Supervisor observer is on port 4357). Log:
   `/var/log/homearchy-stage2.log`. Re-running is safe.

## Testing without hardware

`bin/test-in-vm.sh` builds a test payload, boots the stick image in a libvirt VM
on the current machine, waits for the unattended install, then runs stage 2
inside it (skipping the nested Home Assistant VM). Needs libvirt and ~10 GB.

## Tuning

- `stage2/haos.env`: Home Assistant OS version, VM RAM/CPUs/disk, bridge name.
- `HAOS_SKIP_BRIDGE=1 bin/provision.sh <host>` keeps NAT networking instead of
  bridging (Home Assistant then only reachable from the host).
- USB Zigbee/Z-Wave sticks: list their `vendor:product` IDs in `HAOS_USB_HOSTDEVS`
  (`stage2/haos.env`; find them with `bin/zigbee-probe.sh --list`). Stage 2 attaches
  them idempotently and the VM still boots if one is unplugged. Test a dongle with
  `bin/zigbee-probe.sh` before it is handed to the VM, then set up ZHA with
  `bin/ha-zha-setup.sh` (needs SSH key login to the Home Assistant SSH add-on); see
  `docs/home-assistant.md`.

## Troubleshooting

- **Installer shows the wizard instead of running unattended:** the CIDATA
  partition was not seen. Fallback: write `build/cidata.img` to any second USB
  stick (`sudo dd if=build/cidata.img of=/dev/sdY`) and boot with both inserted.
- **Install fails at partitioning:** `TARGET_DISK_BYTES` is larger than the real
  disk. Smaller is harmless (space is left unused).
- **Wi-Fi:** the Mac mini's Broadcom BCM4360 is handled by the installer
  (`broadcom-wl-dkms`); use Ethernet for the install and for the bridge.
- **Home Assistant has no IP:** check `sudo virsh domifaddr homeassistant --source arp`
  and that `br0` has an address (`ip -4 addr show br0`).

## Layout

```
bin/make-cidata.sh     config.env -> build/cidata/ + build/cidata.img
bin/make-usb.sh        ISO download/verify, dd, append CIDATA partition
bin/provision.sh       push stage2/ over SSH and run it as a systemd unit
bin/test-in-vm.sh      end-to-end test in a local VM
bin/zigbee-probe.sh    list USB/serial devices, test a Zigbee dongle's EZSP handshake
bin/ha-zha-setup.sh    configure the ZHA integration over SSH + the Supervisor API (idempotent)
lib/                   archinstall template (from upstream omarchy-iso tests), signing key
stage2/setup.sh        the host setup (idempotent)
stage2/bootstrap.sh    curl / offline entry point for setup.sh
stage2/haos.env        VM parameters, USB passthrough list (HAOS_USB_HOSTDEVS)
```

Upstream references: [omarchy-iso](https://github.com/omacom/omarchy-iso)
(`omarchy-cidata-load`, `test/integration.d/base-test.sh`),
[Omarchy manual: unattended installs](https://omarchy.org/manual/unattended-installs/).

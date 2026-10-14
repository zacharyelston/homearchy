#!/bin/bash
# Probe a Zigbee coordinator dongle on the host: does the serial port open, and does it speak EZSP?
#
#   bin/zigbee-probe.sh --list          USB devices (vendor:product) and serial ports
#   bin/zigbee-probe.sh [/dev/ttyUSB0]  EZSP reset handshake (default: first /dev/serial/by-id/*)
#
# Reads/writes the port, so it needs the uucp group (re-login after stage2) or sudo.
# Only works while the host owns the dongle: once it is passed through to the Home Assistant VM
# (HAOS_USB_HOSTDEVS in stage2/haos.env) the host no longer has /dev/ttyUSB*. Probe first, or use
# Home Assistant's ZHA setup, which reports the same thing.
#
# EZSP (Silicon Labs EFR32 Zigbee NCP firmware, e.g. SONOFF Dongle Lite MG21) answers an ASH RST
# frame with RSTACK (1a c1 ... 7e) at 115200 baud (460800 on some firmware).
set -euo pipefail

if [[ ${1:-} == --list ]]; then
  echo "USB devices:"
  for d in /sys/bus/usb/devices/*; do
    [[ -f $d/idVendor ]] || continue
    printf '  %s:%s  %s %s\n' "$(<"$d/idVendor")" "$(<"$d/idProduct")" \
      "$(cat "$d/manufacturer" 2>/dev/null)" "$(cat "$d/product" 2>/dev/null)"
  done
  echo "Serial ports (use the by-id path in Home Assistant, not /dev/ttyUSB0):"
  ls -l /dev/serial/by-id/ 2>/dev/null | tail -n +2 || echo "  none"
  exit 0
fi

dev=${1:-$(ls /dev/serial/by-id/* 2>/dev/null | head -n1 || true)}
[[ -n $dev ]] || { echo "no serial device found (passed through to the VM? run with --list)"; exit 2; }
[[ -r $dev && -w $dev ]] || { echo "cannot open $dev: not in group uucp yet (re-login) or run with sudo"; exit 3; }

python3 -I - "$dev" <<'EOF'
import os, select, sys, termios, time
dev = sys.argv[1]
for name, baud in (("115200", termios.B115200), ("460800", termios.B460800)):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd)
    a[0] = a[1] = a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = baud
    a[6][termios.VMIN] = 0; a[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, a); termios.tcflush(fd, termios.TCIOFLUSH)
    os.write(fd, bytes([0x1A, 0xC0, 0x38, 0xBC, 0x7E]))        # ASH RST
    buf, t = b"", time.time()
    while time.time() - t < 2:
        if select.select([fd], [], [], 0.2)[0]:
            buf += os.read(fd, 64)
        if buf.endswith(b"\x7e"):
            break
    os.close(fd)
    if buf.startswith(b"\x1a\xc1"):
        print(f"{dev}: EZSP coordinator answered at {name} baud (RSTACK {buf.hex(' ')})")
        print(f"ZHA settings: radio EZSP, port {dev}, baud {name}, flow control none")
        sys.exit(0)
    print(f"{name} baud: {'unexpected reply ' + buf.hex(' ') if buf else 'no reply'}")
print("no EZSP answer: wrong firmware (Z-Stack/ConBee?), or another program holds the port")
sys.exit(1)
EOF

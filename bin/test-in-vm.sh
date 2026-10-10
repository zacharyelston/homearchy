#!/bin/bash
# End-to-end test on this machine: boot the generated stick image in a libvirt
# VM, let the unattended install run, wait for SSH, then run stage 2 there
# (without creating the nested Home Assistant VM).
#
#   bin/test-in-vm.sh            # build test payload + stick image, run the test
#   bin/test-in-vm.sh --destroy  # tear the test VM down
#
# Needs libvirt on this host and sudo. Takes 10-30 minutes.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T="$REPO/build/test"
VM=omarchy-haos-test
IMG_DIR=/var/lib/libvirt/images/$VM
DISK_BYTES=$((40 * 1024 * 1024 * 1024))
TIMEOUT_MIN=${TIMEOUT_MIN:-40}
V() { sudo virsh "$@"; }

RESUME=0; [[ ${1:-} == --wait ]] && RESUME=1   # skip build + VM creation, just wait/provision
if [[ ${1:-} == --destroy ]]; then
  V destroy "$VM" >/dev/null 2>&1 || true
  V undefine "$VM" --nvram >/dev/null 2>&1 || true
  sudo rm -rf "$IMG_DIR"
  echo "test VM removed"; exit 0
fi

mkdir -p "$T"
if (( ! RESUME )); then
[[ -f $T/test_key ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-haos-test" -f "$T/test_key"
cat > "$T/test.env" <<ENV
USERNAME=tester
PASSWORD='tester-pw'
FULL_NAME='Omarchy Test'
EMAIL='test@example.com'
HOSTNAME=omarchy-test
TIMEZONE=UTC
KB_LAYOUT=us
TARGET_DISK=/dev/vda
TARGET_DISK_BYTES=$DISK_BYTES
SSH_PUBKEY=$T/test_key.pub
OMARCHY_VERSION=${OMARCHY_VERSION:-4.0.4}
ENV

echo "==> Building test cidata and stick image"
"$REPO/bin/make-cidata.sh" -c "$T/test.env" -o "$T"
# make-usb.sh looks for build/cidata.img; point it at the test one.
CONFIG="$T/test.env" BUILD_CIDATA="$T/cidata.img" "$REPO/bin/make-usb.sh" "$T/usb.img"

echo "==> Creating VM $VM"
V destroy "$VM" >/dev/null 2>&1 || true
V undefine "$VM" --nvram >/dev/null 2>&1 || true
sudo rm -rf "$IMG_DIR"; sudo mkdir -p "$IMG_DIR"
sudo qemu-img create -f qcow2 "$IMG_DIR/disk.qcow2" "${DISK_BYTES}" >/dev/null
sudo cp --reflink=auto "$T/usb.img" "$IMG_DIR/usb.img"
sudo virt-install \
  --name "$VM" --memory 4096 --vcpus 2 --cpu host-passthrough \
  --boot uefi \
  --disk "path=$IMG_DIR/disk.qcow2,format=qcow2,bus=virtio,boot.order=1" \
  --disk "path=$IMG_DIR/usb.img,format=raw,bus=usb,removable=on,boot.order=2" \
  --network network=default,model=virtio \
  --graphics vnc,listen=127.0.0.1 --video virtio \
  --osinfo detect=off,require=off --noautoconsole >/dev/null
echo "    console: virt-viewer --connect qemu:///system $VM   (or: sudo virsh screenshot $VM /tmp/s.ppm)"
fi

echo "==> Waiting for the unattended install and first boot (timeout ${TIMEOUT_MIN} min)"
SSH=(ssh -i "$T/test_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR)
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
ip=""
while (( $(date +%s) < deadline )); do
  ip=$(V domifaddr "$VM" 2>/dev/null | awk '/ipv4/ && !f {sub(/\/.*/,"",$4); print $4; f=1}')
  if [[ -n $ip ]] && "${SSH[@]}" "tester@$ip" true 2>/dev/null; then
    echo "    installed system is up at $ip"
    break
  fi
  if [[ $(V domstate "$VM") != running ]]; then
    echo "    VM stopped (install finished without rebooting?); starting it"
    V start "$VM" >/dev/null
  fi
  # Harmless nudge in case the installer shows a "Reboot now" prompt.
  V send-key "$VM" KEY_ENTER >/dev/null 2>&1 || true
  sleep 15
done
[[ -n $ip ]] && "${SSH[@]}" "tester@$ip" true 2>/dev/null || {
  sudo virsh screenshot "$VM" "$T/last-screen.ppm" >/dev/null 2>&1 && echo "    screenshot: $T/last-screen.ppm"
  echo "FAILED: no SSH within ${TIMEOUT_MIN} min"; exit 1
}

echo "==> Checking the installed system"
"${SSH[@]}" "tester@$ip" 'hostnamectl hostname; pacman -Q omarchy; lsblk -f /dev/vda | head -5; sudo -n true 2>/dev/null && echo "sudo: passwordless" || echo "sudo: needs password"'

echo "==> Running stage 2 (HAOS_SKIP_VM=1) via provision.sh"
eval "$(ssh-agent -s)" >/dev/null
ssh-add "$T/test_key" 2>/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT
SUDO_PASS=tester-pw HAOS_SKIP_VM=1 CONFIG="$T/test.env" "$REPO/bin/provision.sh" "$ip" tester

echo "==> Verifying stage 2 results"
"${SSH[@]}" "tester@$ip" 'systemctl is-active libvirtd; nmcli -t -f NAME,DEVICE,STATE connection show --active; ip -4 -o addr show br0; sudo -n ufw status 2>/dev/null | grep -E "br0|virbr0" || true; sudo -n virsh net-list --all 2>/dev/null || true'
echo
echo "PASS: unattended install + stage 2 succeeded in VM $VM ($ip). Remove with: $0 --destroy"

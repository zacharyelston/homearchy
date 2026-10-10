#!/bin/bash
# Stage 2: turn a freshly installed Omarchy box into a Home Assistant host.
# Idempotent; safe to re-run. Run as root:  sudo bash stage2/setup.sh
#
# What it does:
#   1. installs qemu/libvirt (via omarchy-pkg-add, the Omarchy-sanctioned path)
#   2. bridges the wired NIC as br0 so VMs get their own LAN addresses
#   3. opens ufw for bridged and NAT VM traffic
#   4. defines a libvirt network on br0
#   5. downloads Home Assistant OS and creates/autostarts the VM
#
# Env: HAOS_SKIP_VM=1 skips step 5 (used by the VM-in-VM test).
#      HAOS_SKIP_BRIDGE=1 keeps NAT networking (no br0).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$HERE/haos.env"
LOG=/var/log/omarchy-haos-stage2.log
REAL_USER=${STAGE2_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo "")}}

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0"; exit 1; }
exec > >(tee -a "$LOG") 2>&1
echo "=== omarchy-haos stage2 $(date -Is) (user: ${REAL_USER:-none}) ==="

step() { echo; echo "==> $*"; }
ufw_rule() {   # add a ufw rule once
  local status; status=$(ufw status)
  if ! grep -qF -- "$2" <<<"$status"; then ufw $1 >/dev/null; fi
}

step "Syncing package databases and updating the system"
# A fresh install has no synced databases. Do what `omarchy update` does
# (its marker variable satisfies Omarchy's pacman guard), so the new packages
# land on a current system instead of a partial upgrade.
env LC_ALL=C OMARCHY_UPDATE_PACMAN=1 pacman -Syu --noconfirm --overwrite '/usr/share/omarchy/*'

step "Installing virtualization packages"
omarchy-pkg-add qemu-desktop libvirt virt-install virt-manager virt-viewer edk2-ovmf dnsmasq swtpm

step "Enabling libvirtd"
systemctl enable --now libvirtd.service >/dev/null
[[ -n $REAL_USER ]] && usermod -aG libvirt "$REAL_USER"
virsh net-autostart default >/dev/null 2>&1 || true
virsh net-start default >/dev/null 2>&1 || true

step "Firewall rules for VM traffic (ufw)"
ufw_status=$(ufw status 2>/dev/null || true)
if grep -q '^Status: active' <<<"$ufw_status"; then
  ufw_rule "allow in on virbr0 comment libvirt-nat"        "Anywhere on virbr0"
  ufw_rule "allow out on virbr0 comment libvirt-nat"       "ALLOW OUT   Anywhere on virbr0"
  ufw_rule "route allow in on virbr0 comment libvirt-nat"  "ALLOW FWD   Anywhere on virbr0"
  ufw_rule "route allow out on virbr0 comment libvirt-nat" "Anywhere on virbr0         ALLOW FWD"
  if [[ ${HAOS_SKIP_BRIDGE:-0} != 1 ]]; then
    ufw_rule "route allow in on $BRIDGE_NAME comment libvirt-bridge"  "ALLOW FWD   Anywhere on $BRIDGE_NAME"
    ufw_rule "route allow out on $BRIDGE_NAME comment libvirt-bridge" "Anywhere on $BRIDGE_NAME         ALLOW FWD"
  fi
else
  echo "    ufw not active, skipping"
fi

if [[ ${HAOS_SKIP_BRIDGE:-0} != 1 ]]; then
  step "Bridging the wired interface as $BRIDGE_NAME"
  if grep -qx "$BRIDGE_NAME" <<<"$(nmcli -t -f NAME connection show)"; then
    echo "    $BRIDGE_NAME already defined"
  else
    wired=$(nmcli -t -f DEVICE,TYPE,STATE device status | awk -F: '$2=="ethernet" && $3!="unavailable" && !f {print $1; f=1}')
    [[ -n $wired ]] || { echo "    no wired interface found; set HAOS_SKIP_BRIDGE=1 to use NAT instead"; exit 1; }
    mac=$(cat "/sys/class/net/$wired/address")
    old_con=$(nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v d="$wired" '$2==d {print $1}')
    echo "    wired=$wired mac=$mac old-connection='${old_con:-none}'"
    # Keep the NIC's MAC on the bridge so the host keeps its DHCP lease/IP.
    nmcli connection add type bridge ifname "$BRIDGE_NAME" con-name "$BRIDGE_NAME" \
      bridge.stp no ethernet.cloned-mac-address "$mac" \
      ipv4.method auto ipv6.method auto connection.autoconnect yes >/dev/null
    nmcli connection add type ethernet ifname "$wired" con-name "$BRIDGE_NAME-port" \
      master "$BRIDGE_NAME" connection.autoconnect yes >/dev/null
    [[ -n $old_con ]] && nmcli connection modify "$old_con" connection.autoconnect no
    nmcli connection up "$BRIDGE_NAME-port" >/dev/null
    nmcli connection up "$BRIDGE_NAME" >/dev/null || true
  fi
  for _ in $(seq 1 30); do
    [[ -n $(ip -4 -o addr show "$BRIDGE_NAME" 2>/dev/null) ]] && break
    sleep 2
  done
  br_addr=$(ip -4 -o addr show "$BRIDGE_NAME" | awk '{print $4}')
  [[ -n $br_addr ]] || { echo "    $BRIDGE_NAME has no IPv4 address"; exit 1; }
  echo "    $BRIDGE_NAME $br_addr"

  step "libvirt network '$LIBVIRT_NET' on $BRIDGE_NAME"
  if ! virsh net-info "$LIBVIRT_NET" >/dev/null 2>&1; then
    tmp=$(mktemp)
    cat > "$tmp" <<XML
<network>
  <name>$LIBVIRT_NET</name>
  <forward mode="bridge"/>
  <bridge name="$BRIDGE_NAME"/>
</network>
XML
    virsh net-define "$tmp" >/dev/null; rm -f "$tmp"
  fi
  virsh net-autostart "$LIBVIRT_NET" >/dev/null
  virsh net-start "$LIBVIRT_NET" >/dev/null 2>&1 || true
  VM_NET="network=$LIBVIRT_NET"
else
  VM_NET="network=default"
fi

if [[ ${HAOS_SKIP_VM:-0} == 1 ]]; then
  echo; echo "HAOS_SKIP_VM=1: not creating the Home Assistant VM."; exit 0
fi

step "Home Assistant OS $HAOS_VERSION image"
IMG_DIR=/var/lib/libvirt/images
IMG="$IMG_DIR/$VM_NAME.qcow2"
mkdir -p "$IMG_DIR"
if [[ -e $IMG ]]; then
  echo "    $IMG exists, keeping it"
else
  xz_file="$IMG_DIR/haos_ova-$HAOS_VERSION.qcow2.xz"
  curl -fL -C - -o "$xz_file" \
    "https://github.com/home-assistant/operating-system/releases/download/$HAOS_VERSION/haos_ova-$HAOS_VERSION.qcow2.xz"
  xz -dc "$xz_file" > "$IMG.tmp" && mv "$IMG.tmp" "$IMG" && rm -f "$xz_file"
  qemu-img resize "$IMG" "$VM_DISK_SIZE" 2>/dev/null || true
fi

step "Virtual machine '$VM_NAME'"
if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
  echo "    VM exists"
  cur_net=$(virsh domiflist "$VM_NAME" | awk 'NR>2 && $2=="network" && !f {print $3; f=1}')
  want_net=${VM_NET#network=}
  if [[ -n $cur_net && $cur_net != "$want_net" ]]; then
    echo "    switching NIC from '$cur_net' to '$want_net' (VM restarts)"
    virt-xml "$VM_NAME" --edit --network "network=$want_net" >/dev/null
    virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    virsh start "$VM_NAME" >/dev/null
  elif [[ $(virsh domstate "$VM_NAME") != running ]]; then
    virsh start "$VM_NAME" >/dev/null
  fi
else
  virt-install \
    --name "$VM_NAME" \
    --memory "$VM_RAM_MB" \
    --vcpus "$VM_VCPUS" \
    --cpu host-passthrough \
    --boot uefi \
    --import \
    --disk path="$IMG",format=qcow2,bus=virtio,cache=none,discard=unmap \
    --network "$VM_NET",model=virtio \
    --graphics vnc,listen=127.0.0.1 \
    --video virtio \
    --osinfo detect=off,require=off \
    --autostart \
    --noautoconsole >/dev/null
fi

step "Waiting for the VM's IP address"
ip=""
for _ in $(seq 1 60); do
  ip=$(virsh domifaddr "$VM_NAME" --source arp 2>/dev/null | awk '/ipv4/ && !f {sub(/\/.*/,"",$4); print $4; f=1}')
  [[ -z $ip ]] && ip=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ && !f {sub(/\/.*/,"",$4); print $4; f=1}')
  [[ -n $ip ]] && break
  sleep 5
done

echo
echo "=== stage2 complete ==="
if [[ -n $ip ]]; then
  echo "Home Assistant: http://$ip:8123  (also http://homeassistant.local:8123)"
else
  echo "VM is running but has no IP yet. Check later: virsh domifaddr $VM_NAME --source arp"
fi
echo "First boot of Home Assistant takes a few minutes before onboarding appears."
[[ -n $REAL_USER ]] && echo "$REAL_USER was added to the libvirt group; re-login to use virsh without sudo."
exit 0

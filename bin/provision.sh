#!/bin/bash
# Push stage 2 to a freshly installed Omarchy host over SSH and run it there.
#
#   bin/provision.sh <host-or-ip> [user]
#
# The user defaults to USERNAME from config.env. The SSH key from config.env
# must be loaded (ssh-agent) or be the default key. Stage 2 runs as a transient
# systemd unit on the target so it survives the SSH session dropping when the
# wired NIC is moved into the bridge.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONFIG="${CONFIG:-$REPO/config.env}"
# shellcheck disable=SC1090
[[ -f $CONFIG ]] && source "$CONFIG"

HOST=${1:-}; USER_=${2:-${USERNAME:-}}
[[ -n $HOST && -n $USER_ ]] || { sed -n 2,5p "$0"; exit 1; }
target="$USER_@$HOST"
SSH=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)
UNIT=homearchy-stage2
EXTRA_ENV=("-E" "STAGE2_USER=$USER_")
[[ -n ${HAOS_SKIP_VM:-} ]] && EXTRA_ENV+=("-E" "HAOS_SKIP_VM=$HAOS_SKIP_VM")
[[ -n ${HAOS_SKIP_BRIDGE:-} ]] && EXTRA_ENV+=("-E" "HAOS_SKIP_BRIDGE=$HAOS_SKIP_BRIDGE")

echo "==> Waiting for SSH on $target"
until "${SSH[@]}" "$target" true 2>/dev/null; do sleep 5; done

echo "==> Copying stage2/"
rsync -a --delete -e "${SSH[*]}" "$REPO/stage2/" "$target:homearchy-stage2/"

stage_cmd() {  # $1 = sudo invocation to prefix
  echo "$1 systemctl reset-failed $UNIT 2>/dev/null; $1 systemd-run --unit=$UNIT ${EXTRA_ENV[*]} -p WorkingDirectory=\$HOME bash \$HOME/homearchy-stage2/setup.sh"
}
if [[ -n ${SUDO_PASS:-} ]]; then
  # Non-interactive (used by bin/test-in-vm.sh): feed the password to sudo -S.
  echo "==> Starting stage 2 on $HOST (non-interactive sudo)"
  printf '%s\n%s\n' "$SUDO_PASS" "$SUDO_PASS" | "${SSH[@]}" "$target" "$(stage_cmd 'sudo -S -p ""')"
else
  echo "==> Starting stage 2 on $HOST (sudo will ask for $USER_'s password)"
  ssh -t -o StrictHostKeyChecking=accept-new "$target" "$(stage_cmd sudo)"
fi

echo "==> Following progress (reconnects if the bridge switch drops the session)"
while :; do
  state=$("${SSH[@]}" "$target" "systemctl is-active $UNIT" 2>/dev/null) || state=${state:-unreachable}
  case $state in
    active|activating) sleep 10 ;;
    unreachable) sleep 5 ;;
    *) break ;;
  esac
done
"${SSH[@]}" "$target" "tail -n 40 /var/log/homearchy-stage2.log 2>/dev/null || sudo -n tail -n 40 /var/log/homearchy-stage2.log"
if [[ $state == inactive ]] && "${SSH[@]}" "$target" "systemctl show -p Result --value $UNIT | grep -qx success"; then
  echo "==> stage 2 finished on $HOST"
else
  echo "==> stage 2 ended with state '$state' on $HOST; see /var/log/homearchy-stage2.log" >&2
  exit 1
fi

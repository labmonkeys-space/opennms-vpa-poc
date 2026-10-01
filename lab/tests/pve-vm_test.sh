#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# pve-vm.sh must never act on a VMID that belongs to another VM.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../scripts/pve-vm.sh"
[[ -f "$script" ]] || { echo "FAIL $script does not exist"; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Fake remote: VMID 100 exists and is named "someone-else"; log every command.
cat > "$tmp/fake-pve" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$tmp/calls"
case "\$*" in
  "qm status 100") echo "status: running" ;;
  "qm config 100") echo "name: someone-else" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$tmp/fake-pve"
cat > "$tmp/lab.env" <<'EOF'
PVE_TEMPLATE_ID=9000
PVE_STORAGE=local-lvm
PVE_SNIPPET_STORAGE=local
PVE_SNIPPET_DIR=/var/lib/vz/snippets
PVE_BRIDGE=vmbr0
PVE_VLAN_TAG=
GATEWAY=192.0.2.1
DNS_SERVERS=192.0.2.53
K8S_MINOR=1.34
SSH_PUBKEY_FILE=/dev/null
EOF

fail=0
for args in "create vpa-k8s 100 192.0.2.21/24 2 2048 20 $here/../cloud-init/k8s-user-data.yaml.tmpl" "destroy vpa-k8s 100"; do
  : > "$tmp/calls"
  # shellcheck disable=SC2086
  if LAB_ENV="$tmp/lab.env" PVE_SSH="$tmp/fake-pve" bash "$script" $args >/dev/null 2>&1; then
    echo "FAIL '$args' succeeded on a foreign VMID"; fail=1
  elif grep -q -E 'qm (clone|set|destroy|stop|start|resize)' "$tmp/calls"; then
    echo "FAIL '$args' issued a mutating command: $(tr '\n' ';' < "$tmp/calls")"; fail=1
  else
    echo "ok   '${args%% *}' refuses foreign VMID 100"
  fi
done
exit "$fail"

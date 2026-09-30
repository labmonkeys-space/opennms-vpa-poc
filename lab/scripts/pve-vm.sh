#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Create or destroy one lab VM on Proxmox from a cloud-init template.
# Refuses to touch a VMID whose name differs from the one requested.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${LAB_ENV:-$here/../lab.env}"

pve() {
  if [[ -n "${PVE_SSH:-}" ]]; then "$PVE_SSH" "$@"
  else ssh -o BatchMode=yes "${PVE_SSH_USER}@${PVE_HOST}" "$@"; fi
}

vm_name() { pve "qm config $1" 2>/dev/null | sed -n 's/^name: //p'; }

cmd="${1:?usage: pve-vm.sh create|destroy ...}"; shift
case "$cmd" in
  create)
    name="$1" vmid="$2" ip="$3" cores="$4" mem="$5" disk="$6" tmpl="$7"
    if pve "qm status $vmid" >/dev/null 2>&1; then
      existing="$(vm_name "$vmid")"
      if [[ "$existing" != "$name" ]]; then
        echo "VMID $vmid exists as '$existing', not '$name'. Refusing." >&2; exit 1
      fi
      echo "$name ($vmid) already exists"; exit 0
    fi
    SSH_PUBKEY="$(cat "${SSH_PUBKEY_FILE/#\~/$HOME}")"
    VM_IP="$ip"
    DNS_LIST="$(echo "$DNS_SERVERS" | tr ' ' ',' | sed 's/,/, /g')"
    export SSH_PUBKEY VM_IP GATEWAY DNS_LIST K8S_MINOR
    # shellcheck disable=SC2016
    envsubst '${SSH_PUBKEY} ${K8S_MINOR}' < "$tmpl" \
      | pve "cat > ${PVE_SNIPPET_DIR}/${name}-user-data.yaml"
    # shellcheck disable=SC2016
    envsubst '${VM_IP} ${GATEWAY} ${DNS_LIST}' < "$here/../cloud-init/network-config.yaml.tmpl" \
      | pve "cat > ${PVE_SNIPPET_DIR}/${name}-network-config.yaml"
    net="virtio,bridge=${PVE_BRIDGE}${PVE_VLAN_TAG:+,tag=${PVE_VLAN_TAG}}"
    pve "qm clone ${PVE_TEMPLATE_ID} ${vmid} --name ${name} --full 1 --storage ${PVE_STORAGE}"
    pve "qm set ${vmid} --cores ${cores} --cpu host --memory ${mem} --net0 ${net} --cicustom user=${PVE_SNIPPET_STORAGE}:snippets/${name}-user-data.yaml,network=${PVE_SNIPPET_STORAGE}:snippets/${name}-network-config.yaml"
    pve "qm resize ${vmid} scsi0 ${disk}G"
    pve "qm start ${vmid}"
    ;;
  destroy)
    name="$1" vmid="$2"
    if ! pve "qm status $vmid" >/dev/null 2>&1; then echo "$name ($vmid) not present"; exit 0; fi
    existing="$(vm_name "$vmid")"
    if [[ "$existing" != "$name" ]]; then
      echo "VMID $vmid is '$existing', not '$name'. Refusing." >&2; exit 1
    fi
    pve "qm stop ${vmid} --skiplock 1 || true"
    pve "qm destroy ${vmid} --purge 1"
    pve "rm -f ${PVE_SNIPPET_DIR}/${name}-user-data.yaml ${PVE_SNIPPET_DIR}/${name}-network-config.yaml"
    ;;
  *) echo "unknown command $cmd" >&2; exit 2 ;;
esac

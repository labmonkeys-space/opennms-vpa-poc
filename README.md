# opennms-vpa-poc

Proof of concept: vertical pod autoscaling for a minimal OpenNMS deployment that holds nodes and turns SNMPv2c traps into alarms.
The design is in `docs/superpowers/specs/2026-09-30-opennms-vpa-poc-design.md`.

## Layout

- `charts/opennms-vpa`: umbrella chart with PostgreSQL, Kafka, VPA objects and a trap Service, on top of the `core` and `minion` charts from `opennms-helm-charts`.
- `lab/`: Proxmox and kubeadm lab used to measure the chart.
- `runs/`: run manifests and results.

## Requirements

- A checkout of `labmonkeys-space/opennms-helm-charts` on branch `feat/vpa-hooks` next to this repo, or set `HELM_CHARTS_DIR`.
- `helm` with the `helm-unittest` plugin, `shellcheck`, `kubeconform`, `envsubst`, `jq`.

## Checks

    make test

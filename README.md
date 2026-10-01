# opennms-vpa-poc

Proof of concept: vertical pod autoscaling for a minimal OpenNMS deployment that holds nodes and turns SNMPv2c traps into alarms.

## Layout

- `charts/opennms-vpa`: umbrella chart with PostgreSQL, Kafka, VPA objects and a trap Service, on top of the `core` and `minion` charts from `opennms-helm-charts`.
- `lab/`: Proxmox and kubeadm lab used to measure the chart.

## Requirements

- A checkout of `labmonkeys-space/opennms-helm-charts` on branch `feat/vpa-hooks` next to this repo, or set `HELM_CHARTS_DIR`.
- `helm` 4 (the deploy target uses `--force-conflicts`) with the `helm-unittest` plugin.
- `shellcheck`, `kubeconform`, `envsubst`, `jq`.

## Results

- The bare minimum is the smallest size that boots and survives an idle soak.
It is not a size to run on.
The practical floor (Core 2560Mi and 1 CPU, Minion 1536Mi and 250m, Kafka 768Mi and 250m, PostgreSQL 768Mi and 250m) is where a VPA run should start.
- VPA on CPU and memory (arm B) is recommended for growth.
It delivered 4,907,265 of 4,908,000 traps from 10 to 2,000 traps/s at 20,000 nodes, and lost the 735 traps only while Core restarted for a memory resize.
- Static memory fails at 20,000 nodes.
Core was OOMKilled at 2304Mi during the import and again at 2560Mi under traps, so VPA on CPU only (arm A) crashed Core 17 times.
- A Minion resize drops the traps sent during its restart, because nothing listens on the trap port meanwhile.
- The campaign filed [NMS-20391](https://opennms.atlassian.net/browse/NMS-20391) (the Minion image forces `-Xmx`) and [NMS-20392](https://opennms.atlassian.net/browse/NMS-20392) (`/rest/health` reports unhealthy when unused daemons are disabled).

## Checks

    make test

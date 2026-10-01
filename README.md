# opennms-vpa-poc

Proof of concept: vertical pod autoscaling for a minimal OpenNMS deployment that holds nodes and turns SNMPv2c traps into alarms.

## Layout

- `charts/opennms-vpa`: umbrella chart with PostgreSQL, Kafka, VPA objects and a trap Service, on top of the `core` and `minion` charts from `opennms-helm-charts`.
- `lab/`: Proxmox and kubeadm lab used to measure the chart.
- `campaign/` and `tools/`: lab-bound scripts that expect namespace and release `poc`, the lab kubeconfig and `lab/lab.env`.

## Requirements

- A checkout of `labmonkeys-space/opennms-helm-charts` on branch `feat/vpa-hooks` next to this repo, or set `HELM_CHARTS_DIR`.
- `helm` 4 (the deploy target uses `--force-conflicts`) with the `helm-unittest` plugin.
- `shellcheck`, `kubeconform`, `envsubst`, `jq`.

## Results

Run IDs in the chart comments refer to the local campaign record, which is not published.

- The bare minimum is the smallest size that boots and survives an idle soak.
It is not a size to run on.
- The practical floor is Core 2560Mi and 1 CPU, Minion 1536Mi and 250m, Kafka 768Mi and 250m, PostgreSQL 512Mi and 250m.
The chart default for PostgreSQL is 768Mi, which is more than the practical floor used in the campaign.
- Static memory fails at 20,000 nodes.
Phase 2 (VPA Off) OOMKilled Core at 2304Mi during the 20,000-node import.
Arm A (CPU-only VPA, static 2560Mi) OOMKilled Core in its first step and was stopped after step 100.
- VPA on CPU and memory (arm B) completed the ramp from 10 to 2,000 traps/s at 20,000 nodes.
Arm B also had one Core OOMKill at 2560Mi during the initial 20,000-node load, then VPA grew Core's memory.
- Arm B delivered 4,907,265 of 4,908,000 traps sent, a net loss of 735.
The loss was only in steps that contained Core resize restarts.
- Core drained about 665 traps/s.
At 1,000 and 2,000 traps/s a backlog built up in Kafka and was delivered after the ramp.
The trap topic had a single partition.
That the partition count caps Core's rate is an inference, because it was not tested with more partitions.
- A Core resize cost about 1.3k to 1.8k traps at 500 traps/s.
A Minion resize loses about as many traps as arrive during its outage window, because there is a single replica and nothing listens on the trap port meanwhile.
- Caveats: each arm ran once, on one lab node.
The lab shortened the VPA recommender history to 1 h, so a default recommender reacts more slowly.
- The campaign filed [NMS-20391](https://opennms.atlassian.net/browse/NMS-20391) (the Minion image forces `-Xmx`) and [NMS-20392](https://opennms.atlassian.net/browse/NMS-20392) (`/rest/health` reports unhealthy when unused daemons are disabled).

## Checks

    make test

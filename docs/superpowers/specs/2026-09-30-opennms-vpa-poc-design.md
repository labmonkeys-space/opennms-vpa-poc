# OpenNMS VPA proof of concept: design

Date: 2026-09-30
Status: draft, awaiting review
Owner: Ronny Trommer

## Purpose

This PoC investigates Vertical Pod Autoscaling (VPA) for a minimal OpenNMS deployment on Kubernetes.
The deployment has four components: PostgreSQL 18, Horizon Core 36.0.4, Kafka, and one Minion for SNMP trap reception.
The functional scope is narrow: hold devices as nodes, receive SNMPv2c traps and turn them into alarms.

The PoC answers three questions:

1. What is the smallest CPU and memory footprint per component when there is no monitoring workload?
2. How can VPA grow each component as inventory and trap load increase?
3. Which JVM and application settings must an operator set so the processes actually use a resized pod?

The deliverable is a Helm chart that encodes the answers to 2 and 3, plus a measured report that backs every default in it.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Components | PostgreSQL, Core, Kafka, Minion | Minion and Kafka are part of the reference topology, even though Core can receive traps directly. |
| PostgreSQL and Kafka | Plain StatefulSets in the umbrella chart | Smallest footprint, full control of memory flags, no operator dependency. |
| Growth target | Up to 20,000 nodes and 2,000+ traps/s sustained | A large deployment, still below Core's trap ceiling of about 4,700 traps/s measured on 36.0.3. |
| VPA approach | `InPlaceOrRecreate` for Core, Minion and Kafka. `Off` for PostgreSQL. `Recreate` measured as fallback. | CPU follows bursty trap load in place. Memory follows slow inventory growth and needs a JVM restart anyway. |
| Chart base | Umbrella chart on the existing `labmonkeys-space/opennms-helm-charts` `core` and `minion` charts | Findings land in those charts instead of a fork. |

## Assumptions

- A single-node kubeadm cluster on Kubernetes 1.34 with upstream VPA 1.5 is representative of the VPA mechanism.
- Load comes from an SNMPv2c trap flooder and nl6.
- The chart is a PoC artifact. It is not a supported production chart.

## Out of scope

HA, backups, TLS, SNMPv3, Sentinel, flows, performance data collection, service polling, notifications, and pricing.

## Architecture

### Lab

Two VMs on a Proxmox host, cloned from an Ubuntu 24.04 cloud image.

| VM | Size | Role |
|---|---|---|
| `vpa-k8s` | 16 vCPU, 48 GiB, 200 GiB disk | Single-node kubeadm cluster, Kubernetes 1.34, containerd, flannel, local-path-provisioner, metrics-server, upstream VPA 1.5 with the `InPlaceOrRecreate` feature enabled. |
| `vpa-loadgen` | 8 vCPU, 8 GiB | Trap flooder, nl6, requisition generator. Keeps load generation off the system under test. |

The node is sized well above the expected footprint so VPA growth never hits node capacity.
Provisioning uses cloud-init plus a Makefile, so the lab can be destroyed and rebuilt with one command each.
The Proxmox host is a Makefile variable.

### Repositories

- `opennms-vpa-poc` (this repo): umbrella chart, lab Makefile and scripts, run data, report, this spec.
- `opennms-helm-charts`: a branch `feat/vpa-hooks` adds the hooks listed under "Changes to the existing charts". The umbrella references the charts by local path during the PoC.

### Umbrella chart `opennms-vpa`

One release per namespace.

| Component | Source | Kind | VPA `updateMode` |
|---|---|---|---|
| PostgreSQL 18 | umbrella template, image `postgres:18` | StatefulSet + PVC | `Off` |
| Kafka | umbrella template, image `apache/kafka`, KRaft combined mode, one broker | StatefulSet + PVC | `InPlaceOrRecreate` |
| Core 36.0.4 | `core` chart | StatefulSet + PVC | `InPlaceOrRecreate` |
| Minion 36.0.4 | `minion` chart | StatefulSet, 1 replica | `InPlaceOrRecreate` |

The umbrella also owns one `VerticalPodAutoscaler` object per component and a UDP Service for traps.
The trap Service maps port 162 to the Minion's 1162. Its type is a value: NodePort in the lab, LoadBalancer where one is available.

### Core daemon set

Core daemons are switched through the existing chart's `daemons:` block, which maps to the image's `CORE_SERVICE_*_ENABLED` variables.

- On: Eventd, Alarmd, Trapd, Provisiond, Vacuumd, Karaf, JettyServer, KarafStartupMonitor.
- Off: Pollerd, Collectd, Telemetryd, EnhancedLinkd, Discovery, PerspectivePoller, Bsmd, Ticketer, Notifd, Scriptd, Rtcd, PassiveStatusd, EventTranslator, Ackd, Actiond, Statsd, Queued.
- Already off by default in 36.0.4: Syslogd, SnmpPoller, Correlator.

Vacuumd stays on because it runs the key-value store TTL reaper and the database maintenance automations.
Queued only buffers time-series writes, and nothing collects data, so it is off.

Each "off" entry must be verified in Phase 1, because daemons can depend on beans another daemon exports.
Any daemon that cannot be disabled is recorded with the failure it caused.

## JVM and VPA settings

### Facts that drive the settings

1. **Without a CPU limit the JVM sees every node core.** Since JDK 17.0.5 the JVM ignores CPU shares (JDK-8281181 backport). Thread pools are then sized by the node, not the pod. The chart sets `-XX:ActiveProcessorCount` to the CPU value at the component's `maxAllowed`. Pools are sized for the ceiling, and CPU grows in place underneath them.
2. **The heap needs a memory limit to follow.** Memory uses limit equal to request. VPA uses `controlledValues: RequestsAndLimits`. VPA scales only limits that exist, so it scales the memory limit and CPU stays unlimited.
3. **The JVM reads the cgroup limit only at startup.** An in-place memory increase does not grow the heap. The container `resizePolicy` is therefore `cpu: NotRequired` and `memory: RestartContainer`. A memory resize restarts the container in the same pod, keeping the PVC and the node.
4. **The Minion image forces `-Xmx`.** `opennms-container/minion/container-fs/entrypoint.sh:24` always appends `-Xmx${JAVA_MAX_MEM:-2g}`, and `-Xmx` overrides `MaxRAMPercentage`. The chart wraps the entrypoint with a script that reads `/sys/fs/cgroup/memory.max` at every container start and exports `JAVA_MIN_MEM` and `JAVA_MAX_MEM` as a configurable percentage of it. This is also filed as an upstream image improvement.
5. **The JVM keeps memory it has committed.** Without uncommit, resident memory only grows, VPA reads that as demand, and requests only ratchet upward. G1 periodic collection returns unused heap to the OS.
6. **At small sizes the JVM picks SerialGC.** JVM ergonomics selects SerialGC below 2 CPUs or about 1792 MiB of memory, and then G1 uncommit never runs. Every JVM sets `-XX:+UseG1GC` explicitly.
7. **The Core image ships a fixed heap.** The Core Dockerfile sets `ENV JAVA_OPTS="-Xmx1024m -XX:MaxMetaspaceSize=512m"`. The chart's `javaOpts` replaces that variable, so Core's flags must always be set through it.
8. **The VPA updater skips single-replica workloads by default.** Its `--min-replicas` flag defaults to 2, and every component here runs one replica. Each VPA object sets `updatePolicy.minReplicas: 1`, which works even where the updater flags cannot be changed.

### Per-component settings

| Component | Memory settings | Other settings |
|---|---|---|
| Core | `-XX:MaxRAMPercentage` set from the measured non-heap size, `-XX:InitialRAMPercentage=25`, capped `-XX:MaxMetaspaceSize` and `-XX:ReservedCodeCacheSize` | `-XX:G1PeriodicGCInterval`, `-XX:ActiveProcessorCount`, JDBC pool reduced from the default 50 connections to the measured need |
| Minion | Wrapper-computed `-Xms`/`-Xmx` from the cgroup limit | `-XX:G1PeriodicGCInterval`, `-XX:ActiveProcessorCount`, `trapd.threads` at least `cores*2` |
| Kafka | `KAFKA_HEAP_OPTS` with a small heap; the page cache carries the load | Short retention on `OpenNMS.Sink.Trap` and RPC topics, partition count on `OpenNMS.Sink.Trap` exposed as a value |
| PostgreSQL | `shared_buffers`, `work_mem`, `max_connections` sized to Core's pool | Recommendation only, applied by a Helm upgrade |

Core's non-heap footprint (Karaf, Spring, metaspace, code cache, threads) sets the real floor.
A fixed percentage fails at small limits, because non-heap does not shrink with the limit.
Phase 1 measures non-heap with Native Memory Tracking and derives both the caps and the percentage.

`values.yaml` carries a comment on every JVM flag.
The comment states why the flag exists and which PoC run backs its value.

### VPA object shape

Each VPA object sets:

- `updateMode` per component, as above.
- `minAllowed` from the Phase 1 floor.
- `maxAllowed` from the Phase 3 peak plus headroom.
- `controlledResources: [cpu, memory]`.
- `controlledValues: RequestsAndLimits`.
- `updatePolicy.minReplicas: 1`.
- A `containerName: "*"` policy with `mode: "Off"`, so init containers and sidecars are left alone.

### Changes to the existing charts

On branch `feat/vpa-hooks` of `opennms-helm-charts`:

- `resizePolicy` value on the Core and Minion containers.
- Minion entrypoint wrapper for the cgroup-derived heap, off by default.
- Bump `appVersion` to 36.0.4 for the PoC.
- Anything else Phase 1 shows is missing, recorded as it is found.

### Limits of VPA for this workload

- The recommender uses a decaying histogram over 8 days and adds a 15% margin. In the lab the aggregation flags are shortened so ramps are visible in hours. Where the recommender flags cannot be changed, VPA reacts on the scale of days.
- Kafka's working set includes active page cache, which can inflate its memory recommendation.
- Some load levers are outside VPA's reach. The main one is the partition count on `OpenNMS.Sink.Trap`, which caps Core consumer parallelism.
- A CPU-driven signal is unreliable on the Minion under backpressure. `TrapSinkModule` blocks when full, so a stalled Minion shows low CPU.

## Test method

Every run writes a manifest with versions, chart values, VPA flags and the offered load.
Arms of one experiment use the same load generator.
Traps use a spread of reduction keys, because a single key serializes alarm updates and costs about 2.5 times more per trap.
Trap counts come from `eventcreatetime` and Trapd's `rawTrapsReceived`, never from Kafka offsets.

### Phase 0: lab bring-up check

- A test pod receives a CPU resize and keeps running without a restart.
- The same pod receives a memory resize and its container restarts, with the restart count incremented and the pod UID unchanged.
- The Minion wrapper reports the new heap after a memory resize.

### Phase 1: idle floor

Deploy with no nodes and no traps.
Step each component's resources down until startup fails, the readiness probe times out, or the container is OOMKilled.
At each rung record steady-state working set, the Native Memory Tracking breakdown, and time to ready.
Core startup under a small CPU request can take more than 10 minutes, so probe timeouts are part of the result, not noise.

Output: the floor per component, and the chart's default `minAllowed` and startup probe settings.

### Phase 2: inventory growth

Import requisitions of 1,000, 5,000 and 20,000 nodes with no traps.
Record Core and PostgreSQL memory at each size and the VPA recommendation for both.

### Phase 3: trap ramp

At 20,000 nodes step the rate through 10, 100, 500, 1,000 and 2,000 traps/s.
Hold each step until the VPA recommendation settles.
Per step record:

- VPA recommendation against actual usage per component
- resize events and their type, in place or container restart
- traps sent, Trapd `rawTrapsReceived`, alarms created
- Minion UDP receive drops

### Phase 4: resize cost

Under 500 traps/s force one memory resize per component.
Measure time until the component is ready again and the number of traps lost.
Repeat with `updateMode: Recreate` to quantify the fallback for clusters without in-place resize.

## Success criteria

- A floor per component, backed by the Phase 1 evidence.
- VPA follows the ramp to 2,000 traps/s with zero OOMKills and no trap loss outside a forced resize.
- A resize cost figure (ready time and traps lost) per component for `InPlaceOrRecreate` and for `Recreate`.
- Every JVM flag in `values.yaml` backed by a named run.
- The chart installs with one `helm install` on a clean cluster and passes `helm lint`.

## Deliverables

- Umbrella chart `opennms-vpa` in this repo.
- Branch `feat/vpa-hooks` in `opennms-helm-charts`.
- Lab Makefile with `lab-up`, `lab-down`, and one target per phase.
- Run manifests and results under `runs/`.
- An HTML report covering the floor, the ramp, resize cost, and the JVM settings guide.
- Draft upstream issue for the Minion image's forced `-Xmx`.

## Risks

| Risk | Mitigation |
|---|---|
| A daemon listed as "off" is required at runtime | Phase 1 verifies each one. Keep it on and record why. |
| Core does not start below some memory size regardless of heap flags | That size becomes the floor. It is a result, not a failure. |
| In-place resize misbehaves with the JVM, for example the restarted Minion runs on default trap settings until Twin config arrives (up to 60 s) | Phase 4 measures it. Readiness is gated on Twin delivery. |
| The cluster does not offer `InPlaceOrRecreate` | `Recreate` numbers from Phase 4 are the fallback answer. |
| Load generator is the bottleneck at 2,000 traps/s | Confirm generator capacity on `vpa-loadgen` before Phase 3. |

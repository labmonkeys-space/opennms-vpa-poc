# OpenNMS VPA PoC build: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the chart hooks, the `opennms-vpa` umbrella chart and the lab, and prove with Phase 0 that in-place resize reaches the JVMs and that a trap becomes an alarm on an inventoried node.

**Architecture:** Two repos.
`opennms-helm-charts` gets a local branch `feat/vpa-hooks` with four hooks: expanded daemon toggles, `resizePolicy`, a Minion heap wrapper, and appVersion 36.0.4.
`opennms-vpa-poc` holds an umbrella chart that depends on those charts through a gitignored `vendor/` symlink and adds PostgreSQL, Kafka, a trap Service and VPA objects.
The lab is a single-node kubeadm cluster plus a load generator VM on Proxmox, provisioned by cloud-init from a Makefile.

**Tech Stack:** Helm 3 with the helm-unittest plugin 1.1.1, bash, shellcheck, kubeconform, Kubernetes 1.34 (kubeadm, containerd, flannel), upstream VPA 1.5, Proxmox `qm`, cloud-init, net-snmp `snmptrap`.

**Spec:** `docs/superpowers/specs/2026-09-30-opennms-vpa-poc-design.md` (commit `a6a43e8`).

**Not in this plan:** Phases 1 to 4 and the report.
They need measured numbers from this lab to write concrete steps, so they get their own plan once Task 13 passes.
The starting resource values in this plan exist only to make the stack start. Phase 1 replaces them.

## Global Constraints

- The `opennms-vpa-poc` repo is public and covers only the VPA technical problem. The deployment context that motivated it must not appear in any committed file or commit message. The terms to block live in the gitignored file `.check-public-terms`, one extended regex per line, and are never committed. No committed file may contain the real Proxmox host name, lab IP addresses or VMIDs. `make check-public` enforces both and must pass before every push.
- Versions: Horizon Core and Minion `36.0.4`, `postgres:18`, `apache/kafka:3.9.1`, Kubernetes `1.34`, upstream VPA `1.5.x`, Ubuntu `24.04` cloud image.
- Fixed object names, one release per namespace: `postgresql`, `kafka`, `core`, `minion`, `minion-traps`. Lab release and namespace are both `poc`.
- Both repos are Apache-2.0. New shell, YAML and Makefile files start with `# Copyright 2026 Ronny Trommer <ronny@no42.org>` and `# SPDX-License-Identifier: Apache-2.0`. New Helm template files use a `{{- /* ... */ -}}` comment with the same two lines. JSON, Markdown and `.gitignore` get no header. Existing files in `opennms-helm-charts` have no header; leave them that way.
- Commits use Conventional Commits, `git commit -s`, and end with `Assisted-by: ClaudeCode:claude-opus-5-5` then `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Markdown: one sentence per line, no em-dashes.
- On the Proxmox host, only touch VMs this plan creates. Scripts must refuse to act on a VMID whose name differs.
- Nothing is pushed to `opennms-helm-charts`. Pushes to `opennms-vpa-poc` happen only after asking.
- Every JVM flag in `values.yaml` carries a comment saying why it is there.

## Review Focus

1. The Minion wrapper sees no numeric memory limit (file missing, or `max`). Expected: it keeps the image heap defaults and starts, it does not crash-loop. Test: Task 3.
2. The umbrella is built against an `opennms-helm-charts` checkout without the hooks, for example `main`. Expected: `make vendor` fails with a message naming the missing hook, instead of rendering pods without `resizePolicy`. Test: Task 5.
3. A lab VMID in `lab.env` collides with an existing VM. Expected: create and destroy both refuse and leave that VM untouched. Test: Task 10.
4. The trap Service rewrites the source address. Expected: SNMPv2c traps keep the sender's IP so they match the inventoried node. Test: Task 8 (render) and Task 13 (alarm carries the node label).
5. A VPA `updateMode` typo such as `Auto` or `inplace`, or a heap percentage outside 1 to 100. Expected: `helm template` fails with a clear message. Tests: Task 9 and Task 3.

---

## Part A: `opennms-helm-charts` hooks

Working directory for Tasks 1 to 4: `~/workbench/labmonkeys-space/opennms-helm-charts`.

### Task 1: Branch, unit-test harness, expanded daemon toggles

**Files:**
- Modify: `charts/core/templates/_helpers.tpl:402-404` (the `core.daemonsEnvWhitelist` define)
- Modify: `charts/core/values.yaml` (comment above `daemons:`)
- Modify: `charts/core/.helmignore`, `charts/minion/.helmignore` (append `tests/`)
- Modify: `Makefile` (add `unittest` target)
- Create: `charts/core/tests/daemons_test.yaml`

**Interfaces:**
- Produces: `daemons.<short>.enabled` accepts `ackd actiond bsmd collectd discovery enhancedlinkd eventtranslator notifd passivestatusd perspectivepoller pollerd queued rtcd scriptd statsd telemetryd ticketer`. `make unittest` runs every helm-unittest suite and shell test in the repo.

- [ ] **Step 1: Create the branch**

```bash
git switch main && git pull --ff-only && git switch -c feat/vpa-hooks
```

- [ ] **Step 2: Write the failing test** `charts/core/tests/daemons_test.yaml`

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: core daemon toggles
templates:
  - templates/statefulset.yaml
set:
  postgresql.host: pg.example
tests:
  - it: projects CORE_SERVICE_<NAME>_ENABLED=false for every disabled daemon
    set:
      daemons:
        ackd: {enabled: false}
        actiond: {enabled: false}
        bsmd: {enabled: false}
        collectd: {enabled: false}
        discovery: {enabled: false}
        enhancedlinkd: {enabled: false}
        eventtranslator: {enabled: false}
        notifd: {enabled: false}
        passivestatusd: {enabled: false}
        perspectivepoller: {enabled: false}
        pollerd: {enabled: false}
        queued: {enabled: false}
        rtcd: {enabled: false}
        scriptd: {enabled: false}
        statsd: {enabled: false}
        telemetryd: {enabled: false}
        ticketer: {enabled: false}
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_POLLERD_ENABLED, value: "false"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_STATSD_ENABLED, value: "false"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_ACTIOND_ENABLED, value: "false"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_TELEMETRYD_ENABLED, value: "false"}
      - contains:
          path: spec.template.spec.initContainers[?(@.name == "core-init")].env
          content: {name: CORE_SERVICE_COLLECTD_ENABLED, value: "false"}
  - it: emits nothing for a daemon left enabled
    set:
      daemons:
        pollerd: {enabled: true}
    asserts:
      - notContains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_POLLERD_ENABLED, value: "false"}
  - it: still rejects unknown daemon names
    set:
      daemons:
        nosuchd: {enabled: false}
    asserts:
      - failedTemplate:
          errorPattern: 'unknown daemon "nosuchd"'
```

The init-container assertion checks that the install phase (`core-init`) sees the same toggles as the runtime container.
If the render fails on another required value, add that value to the suite-level `set:` block and note it in the commit message.

- [ ] **Step 3: Add the `unittest` target to `Makefile`**

Append after the `lint` target:

```make
.PHONY: unittest
unittest:
	@helm plugin list | grep -q '^unittest' || { echo "Install helm-unittest: helm plugin install https://github.com/helm-unittest/helm-unittest"; exit 1; }
	helm unittest charts/core charts/minion
	@for t in charts/*/tests/*_test.sh; do [ -e "$$t" ] || continue; shellcheck "$$t" && bash "$$t"; done
```

Append `tests/` as a new line to `charts/core/.helmignore` and `charts/minion/.helmignore` so the suites are not packaged.

- [ ] **Step 4: Run the test to verify it fails**

Run: `make unittest`
Expected: FAIL on the first test with `unknown daemon "actiond"` (the whitelist only has `ackd`).

- [ ] **Step 5: Expand the whitelist** in `charts/core/templates/_helpers.tpl`

Replace the body of `core.daemonsEnvWhitelist`:

```
{{- define "core.daemonsEnvWhitelist" -}}
ackd: ACKD
actiond: ACTIOND
bsmd: BSMD
collectd: COLLECTD
discovery: DISCOVERY
enhancedlinkd: ENHANCEDLINKD
eventtranslator: EVENTTRANSLATOR
notifd: NOTIFD
passivestatusd: PASSIVESTATUSD
perspectivepoller: PERSPECTIVEPOLLER
pollerd: POLLERD
queued: QUEUED
rtcd: RTCD
scriptd: SCRIPTD
statsd: STATSD
telemetryd: TELEMETRYD
ticketer: TICKETER
{{- end }}
```

In `charts/core/values.yaml`, replace the sentence `The current whitelist holds only \`ackd\`; expand as operators ask for it.` with `The whitelist covers every daemon that 36.0.4 enables by default and that a trap-to-alarm deployment can run without.`

- [ ] **Step 6: Run the tests to verify they pass**

Run: `make unittest && make lint`
Expected: `3 passed` for the suite and lint OK.

- [ ] **Step 7: Commit**

```bash
git add Makefile charts/core
git commit -s -m "feat(core): allow disabling every default-on daemon not needed for traps

Expands core.daemonsEnvWhitelist to the 36.0.4 service-configuration
toggles that default to enabled, and adds a helm-unittest harness
behind make unittest.

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 2: `resizePolicy` on Core and Minion containers

**Files:**
- Modify: `charts/core/values.yaml` (after `resources: {}`), `charts/minion/values.yaml` (after `resources: {}`)
- Modify: `charts/core/templates/statefulset.yaml` (after the `resources` block of the main container), `charts/minion/templates/statefulset.yaml` (same place)
- Create: `charts/core/tests/resizepolicy_test.yaml`, `charts/minion/tests/resizepolicy_test.yaml`

**Interfaces:**
- Produces: value `resizePolicy` (list of `{resourceName, restartPolicy}`), rendered verbatim on the main container of each chart. Default `[]` renders nothing.

- [ ] **Step 1: Write the failing tests**

`charts/core/tests/resizepolicy_test.yaml`:

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: core resizePolicy
templates:
  - templates/statefulset.yaml
set:
  postgresql.host: pg.example
tests:
  - it: renders no resizePolicy by default
    asserts:
      - notExists:
          path: spec.template.spec.containers[0].resizePolicy
  - it: renders the configured resizePolicy on the main container
    set:
      resizePolicy:
        - {resourceName: cpu, restartPolicy: NotRequired}
        - {resourceName: memory, restartPolicy: RestartContainer}
    asserts:
      - equal:
          path: spec.template.spec.containers[0].resizePolicy
          value:
            - {resourceName: cpu, restartPolicy: NotRequired}
            - {resourceName: memory, restartPolicy: RestartContainer}
```

`charts/minion/tests/resizepolicy_test.yaml`: the same file with `suite: minion resizePolicy` and the suite-level `set:` replaced by:

```yaml
set:
  location: test
```

- [ ] **Step 2: Run to verify they fail**

Run: `make unittest`
Expected: FAIL in both `renders the configured resizePolicy` tests, path not found.

- [ ] **Step 3: Implement**

In both `values.yaml` files, after `resources: {}`:

```yaml

# Container resize policy for in-place pod resize (Kubernetes 1.33+).
# A JVM reads its memory limit only at startup, so pair a memory change with
# a container restart and let CPU change live:
#   - {resourceName: cpu, restartPolicy: NotRequired}
#   - {resourceName: memory, restartPolicy: RestartContainer}
resizePolicy: []
```

In both `statefulset.yaml` files, directly after the main container's `resources` `with` block:

```yaml
          {{- with .Values.resizePolicy }}
          resizePolicy:
            {{- toYaml . | nindent 12 }}
          {{- end }}
```

- [ ] **Step 4: Run to verify they pass**

Run: `make unittest && make lint`
Expected: all suites pass.

- [ ] **Step 5: Commit**

```bash
git add charts/core charts/minion
git commit -s -m "feat(core,minion): expose container resizePolicy

Lets a VerticalPodAutoscaler in InPlaceOrRecreate mode resize CPU live
and restart the container for memory, which a JVM needs to pick up a
new limit.

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 3: Minion heap derived from the cgroup limit

**Files:**
- Create: `charts/minion/files/heap-from-cgroup.sh`
- Create: `charts/minion/tests/heap-from-cgroup_test.sh`
- Create: `charts/minion/templates/minion-heap-wrapper.yaml`
- Create: `charts/minion/tests/heap-wrapper_test.yaml`
- Modify: `charts/minion/values.yaml` (after `javaOpts: ""`)
- Modify: `charts/minion/templates/statefulset.yaml` (main container `command`, `env`, `volumeMounts`; pod `volumes`)

**Interfaces:**
- Consumes: the image entrypoint `/entrypoint.sh`, which appends `-Xms${JAVA_MIN_MEM:-2g} -Xmx${JAVA_MAX_MEM:-2g}` (`opennms-container/minion/container-fs/entrypoint.sh:24` at tag `opennms-36.0.4-1`).
- Produces: values `heapFromCgroup.enabled` (default `false`), `heapFromCgroup.maxPercent` (default `70`), `heapFromCgroup.minPercent` (default `25`). ConfigMap `<fullname>-heap-wrapper` with key `heap-from-cgroup.sh`, mounted at `/opt/heap-from-cgroup`. Wrapper log line on stderr: `heap-from-cgroup: memory.max=<N>MiB JAVA_MIN_MEM=<x>m JAVA_MAX_MEM=<y>m`.

- [ ] **Step 1: Write the failing shell test** `charts/minion/tests/heap-from-cgroup_test.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../files/heap-from-cgroup.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/entrypoint" <<'EOF'
#!/usr/bin/env bash
echo "JAVA_MIN_MEM=${JAVA_MIN_MEM:-unset} JAVA_MAX_MEM=${JAVA_MAX_MEM:-unset} ARGS=$*"
EOF
chmod +x "$tmp/entrypoint"

fail=0
# check <name> <memory.max content or MISSING> <extra env or -> <expected stdout>
check() {
  local name="$1" content="$2" extra="$3" want="$4" file="$tmp/memory.max" got
  rm -f "$file"
  [[ "$content" == MISSING ]] || printf '%s\n' "$content" > "$file"
  local -a envs=(CGROUP_MEMORY_MAX="$file" ENTRYPOINT="$tmp/entrypoint")
  if [[ "$extra" != - ]]; then
    local -a more
    read -r -a more <<< "$extra"
    envs+=("${more[@]}")
  fi
  got="$(env -u JAVA_MIN_MEM -u JAVA_MAX_MEM "${envs[@]}" bash "$script" -f 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then echo "ok   $name"; else echo "FAIL $name: got '$got' want '$want'"; fail=1; fi
}

check "2 GiB limit, default percents" 2147483648 - "JAVA_MIN_MEM=512m JAVA_MAX_MEM=1433m ARGS=-f"
check "4 GiB limit, custom percents" 4294967296 "HEAP_MAX_PERCENT=50 HEAP_MIN_PERCENT=10" "JAVA_MIN_MEM=409m JAVA_MAX_MEM=2048m ARGS=-f"
check "cgroup-derived value wins over operator JAVA_MAX_MEM" 2147483648 "JAVA_MAX_MEM=4g" "JAVA_MIN_MEM=512m JAVA_MAX_MEM=1433m ARGS=-f"
check "no limit keeps image defaults" max - "JAVA_MIN_MEM=unset JAVA_MAX_MEM=unset ARGS=-f"
check "missing cgroup file keeps image defaults" MISSING - "JAVA_MIN_MEM=unset JAVA_MAX_MEM=unset ARGS=-f"

exit "$fail"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash charts/minion/tests/heap-from-cgroup_test.sh`
Expected: every line `FAIL`, because `files/heap-from-cgroup.sh` does not exist.

- [ ] **Step 3: Write the wrapper** `charts/minion/files/heap-from-cgroup.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Derive the Minion heap from the container memory limit, then hand over to the
# image entrypoint. The entrypoint always appends -Xmx${JAVA_MAX_MEM:-2g}, so
# -XX:MaxRAMPercentage never takes effect. Reading memory.max at every start
# lets a container restart pick up a resized limit.
set -euo pipefail

cgroup_file="${CGROUP_MEMORY_MAX:-/sys/fs/cgroup/memory.max}"
max_percent="${HEAP_MAX_PERCENT:-70}"
min_percent="${HEAP_MIN_PERCENT:-25}"

limit="$(cat "$cgroup_file" 2>/dev/null || true)"
if [[ "$limit" =~ ^[0-9]+$ ]]; then
  limit_mib=$(( limit / 1048576 ))
  export JAVA_MAX_MEM="$(( limit_mib * max_percent / 100 ))m"
  export JAVA_MIN_MEM="$(( limit_mib * min_percent / 100 ))m"
  echo "heap-from-cgroup: memory.max=${limit_mib}MiB JAVA_MIN_MEM=${JAVA_MIN_MEM} JAVA_MAX_MEM=${JAVA_MAX_MEM}" >&2
else
  echo "heap-from-cgroup: no numeric memory limit in ${cgroup_file} ('${limit}'), keeping image heap defaults" >&2
fi

exec "${ENTRYPOINT:-/entrypoint.sh}" "$@"
```

- [ ] **Step 4: Run the shell test to verify it passes**

Run: `shellcheck charts/minion/files/heap-from-cgroup.sh charts/minion/tests/heap-from-cgroup_test.sh && bash charts/minion/tests/heap-from-cgroup_test.sh`
Expected: five `ok` lines, exit 0.

- [ ] **Step 5: Write the failing chart test** `charts/minion/tests/heap-wrapper_test.yaml`

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: minion heap wrapper
templates:
  - templates/statefulset.yaml
  - templates/minion-heap-wrapper.yaml
set:
  location: test
tests:
  - it: leaves the image entrypoint alone by default
    template: templates/statefulset.yaml
    asserts:
      - notExists:
          path: spec.template.spec.containers[0].command
  - it: renders no ConfigMap by default
    template: templates/minion-heap-wrapper.yaml
    asserts:
      - hasDocuments: {count: 0}
  - it: wraps the entrypoint and passes the percentages when enabled
    template: templates/statefulset.yaml
    set:
      heapFromCgroup: {enabled: true, maxPercent: 60, minPercent: 20}
    asserts:
      - equal:
          path: spec.template.spec.containers[0].command
          value: [/bin/bash, /opt/heap-from-cgroup/heap-from-cgroup.sh]
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: HEAP_MAX_PERCENT, value: "60"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: HEAP_MIN_PERCENT, value: "20"}
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content: {name: heap-wrapper, mountPath: /opt/heap-from-cgroup, readOnly: true}
  - it: ships the script in a ConfigMap when enabled
    template: templates/minion-heap-wrapper.yaml
    set:
      heapFromCgroup: {enabled: true, maxPercent: 70, minPercent: 25}
    asserts:
      - isKind: {of: ConfigMap}
      - matchRegex:
          path: data["heap-from-cgroup.sh"]
          pattern: 'exec "\$\{ENTRYPOINT:-/entrypoint.sh\}"'
  - it: rejects a max percentage above 100
    template: templates/minion-heap-wrapper.yaml
    set:
      heapFromCgroup: {enabled: true, maxPercent: 120, minPercent: 25}
    asserts:
      - failedTemplate:
          errorPattern: 'heapFromCgroup: need 1 <= minPercent <= maxPercent <= 100'
  - it: rejects a min percentage above the max
    template: templates/minion-heap-wrapper.yaml
    set:
      heapFromCgroup: {enabled: true, maxPercent: 50, minPercent: 60}
    asserts:
      - failedTemplate:
          errorPattern: 'heapFromCgroup: need 1 <= minPercent <= maxPercent <= 100'
```

- [ ] **Step 6: Run to verify it fails**

Run: `helm unittest charts/minion`
Expected: FAIL, template `templates/minion-heap-wrapper.yaml` not found and `heapFromCgroup` nil.

- [ ] **Step 7: Implement the chart wiring**

`charts/minion/values.yaml`, after `javaOpts: ""`:

```yaml

# Derive -Xms/-Xmx from the container memory limit at every container start.
# The image entrypoint always appends -Xmx${JAVA_MAX_MEM:-2g}, which overrides
# -XX:MaxRAMPercentage, so a heap percentage cannot be set through javaOpts.
# Enable this when the memory limit changes at runtime, for example under a
# VerticalPodAutoscaler with resizePolicy memory: RestartContainer.
# When enabled, the derived values replace any JAVA_MIN_MEM/JAVA_MAX_MEM.
heapFromCgroup:
  enabled: false
  # Heap ceiling as a percentage of the memory limit. The rest is left for
  # metaspace, code cache, thread stacks and direct buffers.
  maxPercent: 70
  # Initial heap as a percentage of the memory limit. Kept low so resident
  # memory tracks the live set and a VPA sees real demand.
  minPercent: 25
```

`charts/minion/templates/minion-heap-wrapper.yaml`:

```yaml
{{- /*
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0
*/ -}}
{{- if .Values.heapFromCgroup.enabled }}
{{- $max := int .Values.heapFromCgroup.maxPercent -}}
{{- $min := int .Values.heapFromCgroup.minPercent -}}
{{- if or (lt $min 1) (gt $min $max) (gt $max 100) -}}
{{- fail (printf "heapFromCgroup: need 1 <= minPercent <= maxPercent <= 100, got minPercent=%d maxPercent=%d" $min $max) -}}
{{- end }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "minion.fullname" . }}-heap-wrapper
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "minion.labels" . | nindent 4 }}
data:
  heap-from-cgroup.sh: |
    {{- .Files.Get "files/heap-from-cgroup.sh" | nindent 4 }}
{{- end }}
```

`charts/minion/templates/statefulset.yaml`, main container. Insert after the `imagePullPolicy` line:

```yaml
          {{- if .Values.heapFromCgroup.enabled }}
          command:
            - /bin/bash
            - /opt/heap-from-cgroup/heap-from-cgroup.sh
          {{- end }}
```

Replace the `env:` block with:

```yaml
          env:
            {{- include "minion.runtimeEnv" . | nindent 12 }}
            {{- if .Values.heapFromCgroup.enabled }}
            - name: HEAP_MAX_PERCENT
              value: {{ .Values.heapFromCgroup.maxPercent | quote }}
            - name: HEAP_MIN_PERCENT
              value: {{ .Values.heapFromCgroup.minPercent | quote }}
            {{- end }}
```

Add to `volumeMounts:` before the `with .Values.volumeMounts` line:

```yaml
            {{- if .Values.heapFromCgroup.enabled }}
            - name: heap-wrapper
              mountPath: /opt/heap-from-cgroup
              readOnly: true
            {{- end }}
```

Add to `volumes:` before the `with .Values.volumes` line:

```yaml
        {{- if .Values.heapFromCgroup.enabled }}
        - name: heap-wrapper
          configMap:
            name: {{ include "minion.fullname" . }}-heap-wrapper
        {{- end }}
```

- [ ] **Step 8: Run all tests**

Run: `make unittest && make lint`
Expected: all suites pass, five `ok` lines from the shell test.

- [ ] **Step 9: Commit**

```bash
git add charts/minion
git commit -s -m "feat(minion): optionally derive the heap from the cgroup memory limit

The image entrypoint always appends -Xmx, which defeats
MaxRAMPercentage. A small wrapper reads memory.max at every container
start and exports JAVA_MIN_MEM/JAVA_MAX_MEM, so a container restart
after an in-place memory resize picks up the new limit.

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 4: appVersion 36.0.4, Core `JAVA_OPTS` contract, docs

**Files:**
- Modify: `charts/core/Chart.yaml`, `charts/minion/Chart.yaml`, `charts/sentinel/Chart.yaml`, `charts/opennms-stack/Chart.yaml` (`appVersion` line only)
- Modify: `charts/core/values.yaml` (comment above `javaOpts`)
- Create: `charts/core/tests/javaopts_test.yaml`
- Regenerate: chart `README.md` files via `make readme`

**Interfaces:**
- Produces: pinned behavior that `javaOpts` replaces the image's `JAVA_OPTS` (`-Xmx1024m -XX:MaxMetaspaceSize=512m`) and that an empty `javaOpts` leaves the image default in place.

- [ ] **Step 1: Write the test** `charts/core/tests/javaopts_test.yaml`

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: core JAVA_OPTS
templates:
  - templates/core-configmap.yaml
set:
  postgresql.host: pg.example
tests:
  - it: does not set JAVA_OPTS when javaOpts is empty, so the image default -Xmx1024m applies
    asserts:
      - notExists:
          path: data.JAVA_OPTS
  - it: sets JAVA_OPTS to exactly javaOpts, replacing the image default
    set:
      javaOpts: "-XX:+UseG1GC -XX:MaxRAMPercentage=60"
    asserts:
      - equal:
          path: data.JAVA_OPTS
          value: "-XX:+UseG1GC -XX:MaxRAMPercentage=60"
```

- [ ] **Step 2: Run it**

Run: `helm unittest charts/core`
Expected: PASS. This test pins existing behavior that the umbrella depends on. If it fails, stop and report, because the umbrella's Core JVM flags would not reach the JVM.

- [ ] **Step 3: Update the comment and the versions**

In `charts/core/values.yaml`, replace `# Additional JVM options appended to JAVA_OPTS.` above `javaOpts` with:

```yaml
# JVM options for Core. When set, this REPLACES the image's JAVA_OPTS default
# (-Xmx1024m -XX:MaxMetaspaceSize=512m), so include every heap flag you need.
```

Run:

```bash
sed -i '' 's/^appVersion: "36.0.2"/appVersion: "36.0.4"/' charts/*/Chart.yaml
grep -n appVersion charts/*/Chart.yaml
```

Expected: four lines, all `"36.0.4"`.

- [ ] **Step 4: Lint, test, regenerate docs**

Run: `make unittest && make lint && make readme && git status --short`
Expected: tests and lint pass. README files under `charts/core`, `charts/minion` and possibly the others show as modified.

- [ ] **Step 5: Commit**

```bash
git add charts
git commit -s -m "chore: target Horizon 36.0.4 and document javaOpts replacing JAVA_OPTS

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Part B: `opennms-vpa-poc` umbrella chart

Working directory for Tasks 5 to 13: `~/workbench/labmonkeys-space/opennms-vpa-poc`.

### Task 5: Repo scaffold, vendor link, public-content guard

**Files:**
- Create: `LICENSE` (copy of `../opennms-helm-charts/LICENSE`)
- Create: `README.md`
- Create: `Makefile`
- Modify: `.gitignore`
- Create: `scripts/check-public.sh`
- Create: `tests/make-vendor_test.sh`
- Create: `charts/opennms-vpa/Chart.yaml`, `charts/opennms-vpa/values.yaml`, `charts/opennms-vpa/.helmignore`

**Interfaces:**
- Produces: Make targets `vendor`, `deps`, `lint`, `unittest`, `test-scripts`, `render`, `check-public`, `test` (all of the checks). Variable `HELM_CHARTS_DIR` (default `../opennms-helm-charts`). The umbrella chart `charts/opennms-vpa` with dependencies `core` and `minion` at `0.4.0`.

- [ ] **Step 1: Write the failing test** `tests/make-vendor_test.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# make vendor must refuse an opennms-helm-charts checkout that lacks the VPA hooks.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/charts/core" "$tmp/charts/minion"
echo 'resources: {}' > "$tmp/charts/core/values.yaml"
echo 'resources: {}' > "$tmp/charts/minion/values.yaml"

if out="$(make -C "$root" --no-print-directory vendor HELM_CHARTS_DIR="$tmp" 2>&1)"; then
  echo "FAIL make vendor accepted a checkout without hooks"; exit 1
fi
if [[ "$out" != *"missing VPA hook"* ]]; then
  echo "FAIL unexpected message: $out"; exit 1
fi
echo "ok   make vendor rejects a checkout without hooks"
```

- [ ] **Step 2: Write the `Makefile`**

```make
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0

SHELL           := /bin/bash -o nounset -o pipefail -o errexit
.DEFAULT_GOAL   := help
HELM_CHARTS_DIR ?= ../opennms-helm-charts
CHART           := charts/opennms-vpa
BUILD_DIR       := build

.PHONY: help
help:
	@echo "Targets:"
	@echo "  vendor        Link HELM_CHARTS_DIR (feat/vpa-hooks) into vendor/"
	@echo "  deps          Build umbrella dependencies"
	@echo "  lint          helm lint the umbrella"
	@echo "  unittest      helm-unittest suites of the umbrella"
	@echo "  test-scripts  shellcheck and run the shell tests"
	@echo "  render        Render the umbrella and validate with kubeconform"
	@echo "  check-public  Fail on content that must not be in this public repo"
	@echo "  test          All of the above checks"

.PHONY: vendor
vendor:
	@for f in core:resizePolicy minion:resizePolicy minion:heapFromCgroup; do \
	  c=$${f%%:*}; k=$${f##*:}; \
	  grep -q "^$$k:" "$(HELM_CHARTS_DIR)/charts/$$c/values.yaml" 2>/dev/null || \
	    { echo "missing VPA hook '$$k' in $(HELM_CHARTS_DIR)/charts/$$c. Check out feat/vpa-hooks there."; exit 1; }; \
	done
	@mkdir -p vendor
	@ln -sfn "$(abspath $(HELM_CHARTS_DIR))" vendor/opennms-helm-charts
	@echo "vendor/opennms-helm-charts -> $(abspath $(HELM_CHARTS_DIR))"

.PHONY: deps
deps: vendor
	helm dependency update $(CHART)

.PHONY: lint
lint: deps
	helm lint $(CHART)

.PHONY: unittest
unittest: deps
	helm unittest $(CHART)

.PHONY: test-scripts
test-scripts:
	@for t in tests/*_test.sh lab/tests/*_test.sh; do [ -e "$$t" ] || continue; shellcheck -S warning "$$t" && bash "$$t"; done
	@shellcheck -S warning scripts/*.sh $$(ls lab/scripts/*.sh lab/phase0/*.sh 2>/dev/null)

.PHONY: render
render: deps
	@mkdir -p $(BUILD_DIR)
	helm template poc $(CHART) --namespace poc > $(BUILD_DIR)/render.yaml
	kubeconform -strict -ignore-missing-schemas -summary $(BUILD_DIR)/render.yaml

.PHONY: check-public
check-public:
	scripts/check-public.sh

.PHONY: test
test: lint unittest test-scripts render check-public
```

- [ ] **Step 3: Run the test to verify the guard works**

Run: `bash tests/make-vendor_test.sh`
Expected: `ok   make vendor rejects a checkout without hooks`.
(The guard is written together with the Makefile. Confirm it is load-bearing by temporarily deleting the `@for` loop, re-running to see `FAIL make vendor accepted...`, then restoring it.)

- [ ] **Step 4: Write `scripts/check-public.sh` and the local term list**

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Fails when tracked files, history or commit messages contain terms that must
# stay out of this public repository. Terms come from two gitignored sources:
# .check-public-terms (one extended regex per line) and the real lab hosts and
# addresses in lab/lab.env.
set -euo pipefail
cd "$(dirname "$0")/.."

terms=()
if [[ -f .check-public-terms ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] || terms+=("$line")
  done < .check-public-terms
fi
if [[ -f lab/lab.env ]]; then
  while IFS= read -r value; do
    [[ -n "$value" ]] && terms+=("${value//./\\.}")
  done < <(grep -E '^(PVE_HOST|K8S_IP|LOADGEN_IP|GATEWAY|DNS_SERVERS)=' lab/lab.env \
             | cut -d= -f2- | tr -s ' ,' '\n' | cut -d/ -f1)
fi
if [[ "${#terms[@]}" == 0 ]]; then
  echo "check-public: no terms configured. Create .check-public-terms first." >&2
  exit 2
fi
pattern="$(IFS='|'; echo "${terms[*]}")"

status=0
if git grep -n -i -E "$pattern"; then
  echo "check-public: forbidden content in tracked files" >&2; status=1
fi
if git log -p --all | grep -n -i -E "$pattern"; then
  echo "check-public: forbidden content in history" >&2; status=1
fi
if git log --all --format=%B | grep -n -i -E "$pattern"; then
  echo "check-public: forbidden content in commit messages" >&2; status=1
fi
[[ "$status" == 0 ]] && echo "check-public: clean"
exit "$status"
```

Create `.check-public-terms` with the blocked terms, one extended regex per line.
The terms come from the operator. In this project they are recorded in the agent memory note `opennms-vpa-poc` under "Public-repo rule".
Never paste them into a tracked file, a commit message or this plan.

Run: `chmod +x scripts/check-public.sh && git check-ignore .check-public-terms && scripts/check-public.sh`
Expected: `.check-public-terms` printed by `check-ignore`, then `check-public: clean`.
Then verify it bites: `head -1 .check-public-terms > probe.txt && git add probe.txt && scripts/check-public.sh; git rm -q --cached probe.txt; rm probe.txt`
Expected: the `probe.txt` match and `forbidden content in tracked files`, exit 1.
(With a regex term the probe file holds the regex text. If the regex does not match its own text, write a literal example of the term into `probe.txt` instead.)

- [ ] **Step 5: Write the chart skeleton**

`charts/opennms-vpa/Chart.yaml`:

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
apiVersion: v2
name: opennms-vpa
description: Minimal OpenNMS trap-to-alarm stack with VerticalPodAutoscaler objects (proof of concept)
type: application
version: 0.1.0
appVersion: "36.0.4"
dependencies:
  - name: core
    version: 0.4.0
    repository: file://../../vendor/opennms-helm-charts/charts/core
  - name: minion
    version: 0.4.0
    repository: file://../../vendor/opennms-helm-charts/charts/minion
```

`charts/opennms-vpa/values.yaml` (grows in Tasks 6 to 9):

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# One release per namespace. Object names are fixed (postgresql, kafka, core,
# minion) so the subcharts can address each other without templating.

core:
  fullnameOverride: core
  postgresql:
    host: postgresql
  kafka:
    bootstrapServers: kafka:9092

minion:
  fullnameOverride: minion
  location: poc
  kafka:
    bootstrapServers: kafka:9092
```

`charts/opennms-vpa/.helmignore`:

```
tests/
```

Append to `.gitignore`:

```
# Build and dependency output
build/
vendor/
charts/opennms-vpa/charts/
charts/opennms-vpa/Chart.lock

# Local lab settings and state (real hosts and addresses)
lab/lab.env
lab/.state/

# Terms blocked by make check-public; never committed
.check-public-terms
```

Copy the licence: `cp ../opennms-helm-charts/LICENSE LICENSE`.

`README.md`:

```markdown
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
```

- [ ] **Step 6: Run the checks**

Run: `make lint unittest test-scripts check-public`
Expected: vendor link printed, `helm dependency update` saves `core-0.4.0.tgz` and `minion-0.4.0.tgz`, lint OK, the vendor test prints `ok`, check-public clean.
`helm unittest` has no suites yet. If it exits non-zero only for that reason, that is expected until Task 6.

- [ ] **Step 7: Commit**

```bash
git add LICENSE README.md Makefile .gitignore scripts tests charts
git commit -s -m "build: scaffold umbrella chart, vendor link and public-content guard

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 6: PostgreSQL StatefulSet

**Files:**
- Create: `charts/opennms-vpa/templates/postgresql.yaml`
- Create: `charts/opennms-vpa/tests/postgresql_test.yaml`
- Modify: `charts/opennms-vpa/values.yaml` (add `postgresql:` block)

**Interfaces:**
- Consumes: the Core chart's lab-mode Secret `<release>-opennms-pg-superuser` with keys `username` and `password` (`charts/core/templates/core-pg-superuser-credentials.yaml`).
- Produces: headless Service `postgresql` port 5432 and StatefulSet `postgresql`, container `postgresql`, for VPA `targetRef`.

- [ ] **Step 1: Write the failing test** `charts/opennms-vpa/tests/postgresql_test.yaml`

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: postgresql
templates:
  - templates/postgresql.yaml
release:
  name: poc
  namespace: poc
tests:
  - it: runs postgres:18 as StatefulSet postgresql with the PG 18 data path
    documentSelector: {path: kind, value: StatefulSet}
    asserts:
      - equal: {path: metadata.name, value: postgresql}
      - equal: {path: spec.template.spec.containers[0].name, value: postgresql}
      - equal: {path: spec.template.spec.containers[0].image, value: "postgres:18"}
      - contains:
          path: spec.template.spec.containers[0].volumeMounts
          content: {name: data, mountPath: /var/lib/postgresql}
  - it: takes the superuser from the Core chart's lab-mode Secret
    documentSelector: {path: kind, value: StatefulSet}
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content:
            name: POSTGRES_PASSWORD
            valueFrom: {secretKeyRef: {name: poc-opennms-pg-superuser, key: password}}
  - it: passes memory settings as server arguments
    documentSelector: {path: kind, value: StatefulSet}
    set:
      postgresql.sharedBuffers: 64MB
      postgresql.maxConnections: 80
    asserts:
      - equal:
          path: spec.template.spec.containers[0].args
          value: ["-c", "shared_buffers=64MB", "-c", "max_connections=80"]
  - it: exposes a headless Service named postgresql
    documentSelector: {path: kind, value: Service}
    asserts:
      - equal: {path: metadata.name, value: postgresql}
      - equal: {path: spec.clusterIP, value: None}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make unittest`
Expected: FAIL, template `templates/postgresql.yaml` not found.

- [ ] **Step 3: Implement**

Append to `charts/opennms-vpa/values.yaml`:

```yaml

postgresql:
  image: postgres:18
  storage: 5Gi
  storageClassName: ""
  # PostgreSQL does not follow a resized pod on its own: shared_buffers is fixed
  # at start. Its VPA runs in Off mode and these values are changed by a Helm
  # upgrade after reading the recommendation.
  sharedBuffers: 128MB
  # Every backend costs memory. Must cover Core's JDBC pool (default 50) plus
  # the installer and admin sessions.
  maxConnections: 100
  # Starting values so the stack starts. Phase 1 replaces them with the floor.
  resources:
    requests: {cpu: 250m, memory: 512Mi}
    limits: {memory: 512Mi}
```

`charts/opennms-vpa/templates/postgresql.yaml`:

```yaml
{{- /*
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0

PostgreSQL for Core. The superuser comes from the Core chart's lab-mode Secret
so both sides share one credential without a second Secret.
*/ -}}
{{- $labels := dict "app.kubernetes.io/name" "postgresql" "app.kubernetes.io/instance" .Release.Name -}}
{{- $secret := printf "%s-opennms-pg-superuser" .Release.Name | trunc 63 | trimSuffix "-" -}}
---
apiVersion: v1
kind: Service
metadata:
  name: postgresql
  namespace: {{ .Release.Namespace }}
  labels: {{- toYaml $labels | nindent 4 }}
spec:
  clusterIP: None
  selector: {{- toYaml $labels | nindent 4 }}
  ports:
    - name: postgresql
      port: 5432
      targetPort: postgresql
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql
  namespace: {{ .Release.Namespace }}
  labels: {{- toYaml $labels | nindent 4 }}
spec:
  serviceName: postgresql
  replicas: 1
  selector:
    matchLabels: {{- toYaml $labels | nindent 6 }}
  template:
    metadata:
      labels: {{- toYaml $labels | nindent 8 }}
    spec:
      securityContext:
        fsGroup: 999
      containers:
        - name: postgresql
          image: {{ .Values.postgresql.image | quote }}
          args:
            - "-c"
            - {{ printf "shared_buffers=%s" .Values.postgresql.sharedBuffers | quote }}
            - "-c"
            - {{ printf "max_connections=%v" .Values.postgresql.maxConnections | quote }}
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef: {name: {{ $secret }}, key: username}
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef: {name: {{ $secret }}, key: password}
          ports:
            - name: postgresql
              containerPort: 5432
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -h 127.0.0.1 -U \"$POSTGRES_USER\""]
            periodSeconds: 10
          resources: {{- toYaml .Values.postgresql.resources | nindent 12 }}
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        {{- with .Values.postgresql.storageClassName }}
        storageClassName: {{ . | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.postgresql.storage | quote }}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make unittest render`
Expected: 4 passed; kubeconform summary with 0 errors.

- [ ] **Step 5: Commit**

```bash
git add charts/opennms-vpa
git commit -s -m "feat(chart): add PostgreSQL 18 StatefulSet

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 7: Kafka StatefulSet (KRaft, one broker)

**Files:**
- Create: `charts/opennms-vpa/templates/kafka.yaml`
- Create: `charts/opennms-vpa/tests/kafka_test.yaml`
- Modify: `charts/opennms-vpa/values.yaml` (add `kafka:` block)

**Interfaces:**
- Produces: Service `kafka` port 9092 (matches `bootstrapServers: kafka:9092` from Task 5) and StatefulSet `kafka`, container `kafka`, with `resizePolicy` from `kafka.resizePolicy`.

- [ ] **Step 1: Write the failing test** `charts/opennms-vpa/tests/kafka_test.yaml`

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: kafka
templates:
  - templates/kafka.yaml
release:
  name: poc
  namespace: poc
tests:
  - it: runs apache/kafka 3.9.1 in combined KRaft mode
    documentSelector: {path: kind, value: StatefulSet}
    asserts:
      - equal: {path: metadata.name, value: kafka}
      - equal: {path: spec.template.spec.containers[0].image, value: "apache/kafka:3.9.1"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: KAFKA_PROCESS_ROLES, value: "broker,controller"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: KAFKA_ADVERTISED_LISTENERS, value: "PLAINTEXT://kafka:9092"}
  - it: replaces the image's fixed 1G heap with the configured heap options
    documentSelector: {path: kind, value: StatefulSet}
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: KAFKA_HEAP_OPTS, value: "-XX:+UseG1GC -XX:MaxRAMPercentage=40 -XX:InitialRAMPercentage=10 -XX:G1PeriodicGCInterval=60000"}
  - it: sets retention and partitions from values
    documentSelector: {path: kind, value: StatefulSet}
    set:
      kafka.retentionMs: 600000
      kafka.numPartitions: 4
    asserts:
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: KAFKA_LOG_RETENTION_MS, value: "600000"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: KAFKA_NUM_PARTITIONS, value: "4"}
  - it: renders the resize policy
    documentSelector: {path: kind, value: StatefulSet}
    asserts:
      - equal:
          path: spec.template.spec.containers[0].resizePolicy
          value:
            - {resourceName: cpu, restartPolicy: NotRequired}
            - {resourceName: memory, restartPolicy: RestartContainer}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make unittest`
Expected: FAIL, template `templates/kafka.yaml` not found.

- [ ] **Step 3: Implement**

Append to `charts/opennms-vpa/values.yaml`:

```yaml

kafka:
  image: apache/kafka:3.9.1
  # 22-character base64 cluster id used to format storage on first start.
  clusterId: MkU3OEVBNTcwNTJENDM2Qk
  storage: 5Gi
  storageClassName: ""
  # Traps and RPC messages are consumed within seconds. One hour keeps disk small.
  retentionMs: 3600000
  # Applies to every auto-created topic, including OpenNMS.Sink.Trap. Core's
  # trap consumer parallelism is capped by this number, and VPA cannot change it.
  numPartitions: 1
  # Kafka lives on the page cache, so its heap stays small.
  #   UseG1GC:              ergonomics picks SerialGC below 2 CPUs or ~1792 MiB.
  #   MaxRAMPercentage:     heap follows the container limit after a restart.
  #   InitialRAMPercentage: resident memory starts low so VPA sees real demand.
  #   G1PeriodicGCInterval: returns unused heap to the OS.
  heapOpts: "-XX:+UseG1GC -XX:MaxRAMPercentage=40 -XX:InitialRAMPercentage=10 -XX:G1PeriodicGCInterval=60000"
  # Starting values so the stack starts. Phase 1 replaces them with the floor.
  resources:
    requests: {cpu: 250m, memory: 1Gi}
    limits: {memory: 1Gi}
  resizePolicy:
    - {resourceName: cpu, restartPolicy: NotRequired}
    - {resourceName: memory, restartPolicy: RestartContainer}
```

`charts/opennms-vpa/templates/kafka.yaml`:

```yaml
{{- /*
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0

Single Kafka broker in combined KRaft mode for Core to Minion IPC.
*/ -}}
{{- $labels := dict "app.kubernetes.io/name" "kafka" "app.kubernetes.io/instance" .Release.Name -}}
---
apiVersion: v1
kind: Service
metadata:
  name: kafka
  namespace: {{ .Release.Namespace }}
  labels: {{- toYaml $labels | nindent 4 }}
spec:
  selector: {{- toYaml $labels | nindent 4 }}
  ports:
    - name: kafka
      port: 9092
      targetPort: kafka
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: kafka
  namespace: {{ .Release.Namespace }}
  labels: {{- toYaml $labels | nindent 4 }}
spec:
  serviceName: kafka
  replicas: 1
  selector:
    matchLabels: {{- toYaml $labels | nindent 6 }}
  template:
    metadata:
      labels: {{- toYaml $labels | nindent 8 }}
    spec:
      securityContext:
        fsGroup: 1000
      containers:
        - name: kafka
          image: {{ .Values.kafka.image | quote }}
          env:
            - {name: CLUSTER_ID, value: {{ .Values.kafka.clusterId | quote }}}
            - {name: KAFKA_NODE_ID, value: "1"}
            - {name: KAFKA_PROCESS_ROLES, value: "broker,controller"}
            - {name: KAFKA_LISTENERS, value: "PLAINTEXT://:9092,CONTROLLER://:9093"}
            - {name: KAFKA_ADVERTISED_LISTENERS, value: "PLAINTEXT://kafka:9092"}
            - {name: KAFKA_CONTROLLER_LISTENER_NAMES, value: "CONTROLLER"}
            - {name: KAFKA_LISTENER_SECURITY_PROTOCOL_MAP, value: "CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT"}
            - {name: KAFKA_CONTROLLER_QUORUM_VOTERS, value: "1@localhost:9093"}
            - {name: KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR, value: "1"}
            - {name: KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR, value: "1"}
            - {name: KAFKA_TRANSACTION_STATE_LOG_MIN_ISR, value: "1"}
            - {name: KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS, value: "0"}
            - {name: KAFKA_LOG_DIRS, value: "/var/lib/kafka/data"}
            - {name: KAFKA_LOG_RETENTION_MS, value: {{ .Values.kafka.retentionMs | quote }}}
            - {name: KAFKA_NUM_PARTITIONS, value: {{ .Values.kafka.numPartitions | quote }}}
            - {name: KAFKA_HEAP_OPTS, value: {{ .Values.kafka.heapOpts | quote }}}
          ports:
            - name: kafka
              containerPort: 9092
          readinessProbe:
            tcpSocket: {port: kafka}
            periodSeconds: 10
          resources: {{- toYaml .Values.kafka.resources | nindent 12 }}
          {{- with .Values.kafka.resizePolicy }}
          resizePolicy: {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: data
              mountPath: /var/lib/kafka/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
        {{- with .Values.kafka.storageClassName }}
        storageClassName: {{ . | quote }}
        {{- end }}
        resources:
          requests:
            storage: {{ .Values.kafka.storage | quote }}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make unittest render`
Expected: all suites pass, kubeconform 0 errors.

- [ ] **Step 5: Commit**

```bash
git add charts/opennms-vpa
git commit -s -m "feat(chart): add single-broker KRaft Kafka StatefulSet

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 8: Core and Minion settings, trap Service

**Files:**
- Modify: `charts/opennms-vpa/values.yaml` (`core:` and `minion:` blocks, add `trapService:`)
- Create: `charts/opennms-vpa/templates/trap-service.yaml`
- Create: `charts/opennms-vpa/tests/core-minion_test.yaml`, `charts/opennms-vpa/tests/trap-service_test.yaml`

**Interfaces:**
- Consumes: hooks from Tasks 1 to 3 (`daemons`, `resizePolicy`, `heapFromCgroup`); Minion pod labels `app.kubernetes.io/name: minion`, `app.kubernetes.io/instance: <release>`.
- Produces: StatefulSets `core` (container `core`) and `minion` (container `minion`); Service `minion-traps` UDP 162 to 1162, NodePort `trapService.nodePort` (default 30162) with `externalTrafficPolicy: Local`.

- [ ] **Step 1: Write the failing tests**

`charts/opennms-vpa/tests/core-minion_test.yaml`:

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: core and minion settings
release:
  name: poc
  namespace: poc
tests:
  - it: names the Core StatefulSet core and disables unused daemons
    template: charts/core/templates/statefulset.yaml
    asserts:
      - equal: {path: metadata.name, value: core}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_POLLERD_ENABLED, value: "false"}
      - contains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_COLLECTD_ENABLED, value: "false"}
      - notContains:
          path: spec.template.spec.containers[0].env
          content: {name: CORE_SERVICE_TRAPD_ENABLED, value: "false"}
      - equal:
          path: spec.template.spec.containers[0].resizePolicy
          value:
            - {resourceName: cpu, restartPolicy: NotRequired}
            - {resourceName: memory, restartPolicy: RestartContainer}
  - it: gives Core G1 and a percentage heap with no fixed -Xmx
    template: charts/core/templates/core-configmap.yaml
    asserts:
      - matchRegex: {path: data.JAVA_OPTS, pattern: '-XX:\+UseG1GC'}
      - matchRegex: {path: data.JAVA_OPTS, pattern: '-XX:MaxRAMPercentage=\d+'}
      - matchRegex: {path: data.JAVA_OPTS, pattern: '-XX:ActiveProcessorCount=\d+'}
      - notMatchRegex: {path: data.JAVA_OPTS, pattern: '-Xmx'}
  - it: runs the Minion with the cgroup heap wrapper and a resize policy
    template: charts/minion/templates/statefulset.yaml
    asserts:
      - equal: {path: metadata.name, value: minion}
      - equal:
          path: spec.template.spec.containers[0].command
          value: [/bin/bash, /opt/heap-from-cgroup/heap-from-cgroup.sh]
      - equal:
          path: spec.template.spec.containers[0].resizePolicy
          value:
            - {resourceName: cpu, restartPolicy: NotRequired}
            - {resourceName: memory, restartPolicy: RestartContainer}
```

`charts/opennms-vpa/tests/trap-service_test.yaml`:

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: trap service
templates:
  - templates/trap-service.yaml
release:
  name: poc
  namespace: poc
tests:
  - it: forwards UDP 162 to the Minion on 1162 and keeps the source address
    asserts:
      - equal: {path: metadata.name, value: minion-traps}
      - equal: {path: spec.type, value: NodePort}
      - equal: {path: spec.externalTrafficPolicy, value: Local}
      - equal:
          path: spec.ports[0]
          value: {name: snmp-trap, protocol: UDP, port: 162, targetPort: 1162, nodePort: 30162}
      - equal:
          path: spec.selector
          value: {app.kubernetes.io/name: minion, app.kubernetes.io/instance: poc}
  - it: omits externalTrafficPolicy and nodePort for ClusterIP
    set:
      trapService.type: ClusterIP
    asserts:
      - notExists: {path: spec.externalTrafficPolicy}
      - notExists: {path: spec.ports[0].nodePort}
```

- [ ] **Step 2: Run to verify they fail**

Run: `make unittest`
Expected: FAIL: env lacks `CORE_SERVICE_POLLERD_ENABLED`, `JAVA_OPTS` missing, no `command` on the Minion, trap-service template not found.

- [ ] **Step 3: Implement values**

Replace the `core:` and `minion:` blocks in `charts/opennms-vpa/values.yaml` with:

```yaml
core:
  fullnameOverride: core
  postgresql:
    host: postgresql
  kafka:
    bootstrapServers: kafka:9092
  persistence:
    size: 5Gi
  # Nothing polls, so the ICMP sysctl is not needed.
  icmp:
    enabled: false
  # Admin password bootstrap pulls an extra image. Not needed for the PoC.
  webAdmin:
    enabled: false
  # Only Eventd, Alarmd, Trapd, Provisiond, Vacuumd and the Jetty/Karaf
  # services are needed to hold nodes and turn traps into alarms.
  # Vacuumd stays on: it runs the key-value TTL reaper and DB maintenance.
  daemons:
    ackd: {enabled: false}
    actiond: {enabled: false}
    bsmd: {enabled: false}
    collectd: {enabled: false}
    discovery: {enabled: false}
    enhancedlinkd: {enabled: false}
    eventtranslator: {enabled: false}
    notifd: {enabled: false}
    passivestatusd: {enabled: false}
    perspectivepoller: {enabled: false}
    pollerd: {enabled: false}
    queued: {enabled: false}
    rtcd: {enabled: false}
    scriptd: {enabled: false}
    statsd: {enabled: false}
    telemetryd: {enabled: false}
    ticketer: {enabled: false}
  # Replaces the image default -Xmx1024m. Starting values; Phase 1 derives the
  # percentage and caps from the measured non-heap size.
  #   UseG1GC:                ergonomics picks SerialGC below 2 CPUs or ~1792 MiB.
  #   MaxRAMPercentage=60:    heap follows the container limit after a restart.
  #   InitialRAMPercentage=25: resident memory starts low so VPA sees real demand.
  #   MaxMetaspaceSize, ReservedCodeCacheSize: bound non-heap so the percentage holds.
  #   G1PeriodicGCInterval:   returns unused heap to the OS.
  #   ActiveProcessorCount=4: without a CPU limit the JVM sizes pools to the node's
  #                           cores; pin to the VPA maxAllowed CPU instead.
  javaOpts: "-XX:+UseG1GC -XX:MaxRAMPercentage=60 -XX:InitialRAMPercentage=25 -XX:MaxMetaspaceSize=512m -XX:ReservedCodeCacheSize=240m -XX:G1PeriodicGCInterval=60000 -XX:ActiveProcessorCount=4"
  # Starting values so the stack starts. Phase 1 replaces them with the floor.
  resources:
    requests: {cpu: "1", memory: 3Gi}
    limits: {memory: 3Gi}
  resizePolicy:
    - {resourceName: cpu, restartPolicy: NotRequired}
    - {resourceName: memory, restartPolicy: RestartContainer}

minion:
  fullnameOverride: minion
  location: poc
  kafka:
    bootstrapServers: kafka:9092
  persistence:
    size: 1Gi
  icmp:
    enabled: false
  # The image forces -Xmx; derive it from the memory limit at every start.
  heapFromCgroup:
    enabled: true
    maxPercent: 60
    minPercent: 25
  #   UseG1GC, G1PeriodicGCInterval: as for Core.
  #   ActiveProcessorCount=2: sizes trapd.threads (default cores*2) and GC threads
  #                           to the VPA maxAllowed CPU, not the node.
  javaOpts: "-XX:+UseG1GC -XX:G1PeriodicGCInterval=60000 -XX:ActiveProcessorCount=2"
  # Starting values so the stack starts. Phase 1 replaces them with the floor.
  resources:
    requests: {cpu: 500m, memory: 1536Mi}
    limits: {memory: 1536Mi}
  resizePolicy:
    - {resourceName: cpu, restartPolicy: NotRequired}
    - {resourceName: memory, restartPolicy: RestartContainer}

trapService:
  # NodePort in the lab, LoadBalancer where the cluster provides one.
  type: NodePort
  nodePort: 30162
```

- [ ] **Step 4: Implement** `charts/opennms-vpa/templates/trap-service.yaml`

```yaml
{{- /*
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0

SNMP trap ingress to the Minion. SNMPv2c traps are matched to nodes by the
packet source address, so NodePort and LoadBalancer use
externalTrafficPolicy: Local to avoid SNAT.
*/ -}}
---
apiVersion: v1
kind: Service
metadata:
  name: minion-traps
  namespace: {{ .Release.Namespace }}
  labels:
    app.kubernetes.io/name: minion-traps
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: {{ .Values.trapService.type }}
  {{- if ne .Values.trapService.type "ClusterIP" }}
  externalTrafficPolicy: Local
  {{- end }}
  selector:
    app.kubernetes.io/name: minion
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - name: snmp-trap
      protocol: UDP
      port: 162
      targetPort: 1162
      {{- if and (eq .Values.trapService.type "NodePort") .Values.trapService.nodePort }}
      nodePort: {{ .Values.trapService.nodePort }}
      {{- end }}
```

- [ ] **Step 5: Run to verify they pass**

Run: `make unittest render`
Expected: all suites pass, kubeconform 0 errors.

- [ ] **Step 6: Commit**

```bash
git add charts/opennms-vpa
git commit -s -m "feat(chart): configure Core and Minion for traps and add trap Service

Core runs only the daemons needed to hold nodes and raise alarms. Both
JVMs use G1, a pinned processor count and a heap that follows the
container limit. The trap Service keeps the source address so SNMPv2c
traps match their nodes.

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 9: VerticalPodAutoscaler objects

**Files:**
- Create: `charts/opennms-vpa/templates/vpa.yaml`
- Create: `charts/opennms-vpa/tests/vpa_test.yaml`
- Modify: `charts/opennms-vpa/values.yaml` (add `vpa:` block)

**Interfaces:**
- Consumes: StatefulSet and container names from Tasks 6 to 8.
- Produces: one `autoscaling.k8s.io/v1` `VerticalPodAutoscaler` per entry in `vpa.components`, named after the key (`postgresql`, `kafka`, `core`, `minion`). Allowed `updateMode`: `Off`, `Initial`, `Recreate`, `InPlaceOrRecreate`.

- [ ] **Step 1: Write the failing test** `charts/opennms-vpa/tests/vpa_test.yaml`

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
suite: vpa
templates:
  - templates/vpa.yaml
release:
  name: poc
  namespace: poc
tests:
  - it: renders one VPA per component
    asserts:
      - hasDocuments: {count: 4}
      - isKind: {of: VerticalPodAutoscaler}
  - it: resizes Core in place, on a single replica, with limits scaled
    documentSelector: {path: metadata.name, value: core}
    asserts:
      - equal:
          path: spec.targetRef
          value: {apiVersion: apps/v1, kind: StatefulSet, name: core}
      - equal: {path: spec.updatePolicy.updateMode, value: InPlaceOrRecreate}
      - equal: {path: spec.updatePolicy.minReplicas, value: 1}
      - equal: {path: spec.resourcePolicy.containerPolicies[0].containerName, value: core}
      - equal: {path: spec.resourcePolicy.containerPolicies[0].controlledValues, value: RequestsAndLimits}
      - equal:
          path: spec.resourcePolicy.containerPolicies[1]
          value: {containerName: "*", mode: "Off"}
  - it: only recommends for PostgreSQL
    documentSelector: {path: metadata.name, value: postgresql}
    asserts:
      - equal: {path: spec.updatePolicy.updateMode, value: "Off"}
  - it: renders nothing when disabled
    set:
      vpa.enabled: false
    asserts:
      - hasDocuments: {count: 0}
  - it: rejects an unknown updateMode
    set:
      vpa.components.core.updateMode: Auto
    asserts:
      - failedTemplate:
          errorPattern: 'vpa.components.core.updateMode "Auto" is not one of Off, Initial, Recreate, InPlaceOrRecreate'
```

- [ ] **Step 2: Run to verify it fails**

Run: `make unittest`
Expected: FAIL, template `templates/vpa.yaml` not found.

- [ ] **Step 3: Implement**

Append to `charts/opennms-vpa/values.yaml`:

```yaml

vpa:
  enabled: true
  # minAllowed and maxAllowed are starting bounds. Phase 1 sets minAllowed to
  # the measured floor; Phase 3 sets maxAllowed from the peak plus headroom.
  # Keep each JVM's ActiveProcessorCount equal to its maxAllowed CPU.
  components:
    postgresql:
      kind: StatefulSet
      name: postgresql
      container: postgresql
      # shared_buffers needs a restart and a config change; apply by Helm upgrade.
      updateMode: "Off"
      minAllowed: {cpu: 100m, memory: 256Mi}
      maxAllowed: {cpu: "2", memory: 4Gi}
    kafka:
      kind: StatefulSet
      name: kafka
      container: kafka
      updateMode: InPlaceOrRecreate
      minAllowed: {cpu: 100m, memory: 512Mi}
      maxAllowed: {cpu: "2", memory: 4Gi}
    core:
      kind: StatefulSet
      name: core
      container: core
      updateMode: InPlaceOrRecreate
      minAllowed: {cpu: 250m, memory: 2Gi}
      maxAllowed: {cpu: "4", memory: 12Gi}
    minion:
      kind: StatefulSet
      name: minion
      container: minion
      updateMode: InPlaceOrRecreate
      minAllowed: {cpu: 100m, memory: 1Gi}
      maxAllowed: {cpu: "2", memory: 4Gi}
```

`charts/opennms-vpa/templates/vpa.yaml`:

```yaml
{{- /*
Copyright 2026 Ronny Trommer <ronny@no42.org>
SPDX-License-Identifier: Apache-2.0

One VerticalPodAutoscaler per component.
- minReplicas: 1   the updater skips workloads below --min-replicas (default 2),
                   and every component here runs one replica.
- RequestsAndLimits scales the memory limit with the request, which the JVM heap
                   percentage follows. CPU has no limit, so none is added.
- "*" mode Off     leaves init containers and sidecars alone.
*/ -}}
{{- if .Values.vpa.enabled }}
{{- $modes := list "Off" "Initial" "Recreate" "InPlaceOrRecreate" }}
{{- range $key, $c := .Values.vpa.components }}
{{- if not (has $c.updateMode $modes) }}
{{- fail (printf "vpa.components.%s.updateMode %q is not one of Off, Initial, Recreate, InPlaceOrRecreate" $key $c.updateMode) }}
{{- end }}
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: {{ $key }}
  namespace: {{ $.Release.Namespace }}
  labels:
    app.kubernetes.io/name: {{ $key }}
    app.kubernetes.io/instance: {{ $.Release.Name }}
spec:
  targetRef:
    apiVersion: apps/v1
    kind: {{ $c.kind }}
    name: {{ $c.name }}
  updatePolicy:
    updateMode: {{ $c.updateMode | quote }}
    minReplicas: 1
  resourcePolicy:
    containerPolicies:
      - containerName: {{ $c.container | quote }}
        controlledResources: ["cpu", "memory"]
        controlledValues: RequestsAndLimits
        minAllowed: {{- toYaml $c.minAllowed | nindent 10 }}
        maxAllowed: {{- toYaml $c.maxAllowed | nindent 10 }}
      - containerName: "*"
        mode: "Off"
{{- end }}
{{- end }}
```

- [ ] **Step 4: Run to verify it passes**

Run: `make test`
Expected: every suite passes, shell tests `ok`, kubeconform 0 errors (VPA skipped as missing schema), `check-public: clean`.

- [ ] **Step 5: Commit**

```bash
git add charts/opennms-vpa
git commit -s -m "feat(chart): add VerticalPodAutoscaler per component

InPlaceOrRecreate for Core, Minion and Kafka, recommendation only for
PostgreSQL. minReplicas: 1 is required because the VPA updater skips
single-replica workloads by default.

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Part C: Lab and Phase 0

### Task 10: Lab VMs on Proxmox

**Files:**
- Create: `lab/lab.env.example`
- Create: `lab/cloud-init/k8s-user-data.yaml.tmpl`, `lab/cloud-init/loadgen-user-data.yaml.tmpl`, `lab/cloud-init/network-config.yaml.tmpl`
- Create: `lab/scripts/pve-vm.sh`
- Create: `lab/tests/pve-vm_test.sh`
- Modify: `Makefile` (targets `lab-up`, `lab-down`, `lab-kubeconfig`)

**Interfaces:**
- Produces: `lab/lab.env` variables (see example). `lab/scripts/pve-vm.sh create <name> <vmid> <ip/cidr> <cores> <mem_mib> <disk_gb> <user-data-template>` and `destroy <name> <vmid>`. Env `PVE_SSH` overrides the remote command runner (used by tests). `lab/.state/kubeconfig` after `make lab-up`. SSH user `lab` on both VMs.

- [ ] **Step 1: Write the failing guard test** `lab/tests/pve-vm_test.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# pve-vm.sh must never act on a VMID that belongs to another VM.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../scripts/pve-vm.sh"
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash lab/tests/pve-vm_test.sh`
Expected: `FAIL` lines, because `lab/scripts/pve-vm.sh` does not exist.

- [ ] **Step 3: Write** `lab/scripts/pve-vm.sh`

```bash
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `shellcheck -S warning lab/scripts/pve-vm.sh lab/tests/pve-vm_test.sh && bash lab/tests/pve-vm_test.sh`
Expected: `ok   'create' refuses foreign VMID 100` and `ok   'destroy' refuses foreign VMID 100`.

- [ ] **Step 5: Write the cloud-init templates**

`lab/cloud-init/network-config.yaml.tmpl`:

```yaml
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
version: 2
ethernets:
  eth0:
    match:
      name: "e*"
    set-name: eth0
    addresses: [${VM_IP}]
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses: [${DNS_LIST}]
```

`lab/cloud-init/k8s-user-data.yaml.tmpl`:

```yaml
#cloud-config
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Single-node kubeadm cluster with containerd (systemd cgroups) and flannel's pod CIDR.
hostname: vpa-k8s
preserve_hostname: false
ssh_pwauth: false
users:
  - name: lab
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: ["${SSH_PUBKEY}"]
package_update: true
packages: [containerd, apt-transport-https, ca-certificates, curl, gpg, jq]
write_files:
  - path: /etc/modules-load.d/k8s.conf
    content: |
      overlay
      br_netfilter
  - path: /etc/sysctl.d/99-k8s.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
  - path: /etc/kubeadm.yaml
    content: |
      apiVersion: kubeadm.k8s.io/v1beta4
      kind: ClusterConfiguration
      kubernetesVersion: "@KVER@"
      networking:
        podSubnet: 10.244.0.0/16
      ---
      apiVersion: kubelet.config.k8s.io/v1beta1
      kind: KubeletConfiguration
      cgroupDriver: systemd
runcmd:
  - [modprobe, overlay]
  - [modprobe, br_netfilter]
  - [sysctl, --system]
  - [sh, -c, "mkdir -p /etc/containerd && containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml && systemctl restart containerd"]
  - [sh, -c, "install -d -m 0755 /etc/apt/keyrings && curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"]
  - [sh, -c, "echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /' > /etc/apt/sources.list.d/kubernetes.list"]
  - [sh, -c, "apt-get update && apt-get install -y kubelet kubeadm kubectl && apt-mark hold kubelet kubeadm kubectl"]
  - [sh, -c, "sed -i \"s/@KVER@/$(kubeadm version -o short)/\" /etc/kubeadm.yaml && kubeadm init --config /etc/kubeadm.yaml"]
  - [sh, -c, "install -d -o lab -g lab /home/lab/.kube && install -o lab -g lab -m 0600 /etc/kubernetes/admin.conf /home/lab/.kube/config"]
  - [sh, -c, "KUBECONFIG=/etc/kubernetes/admin.conf kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true"]
```

`lab/cloud-init/loadgen-user-data.yaml.tmpl`:

```yaml
#cloud-config
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Trap sender. Phase 1+ tooling (flooder, nl6) is added by the campaign plan.
hostname: vpa-loadgen
preserve_hostname: false
ssh_pwauth: false
users:
  - name: lab
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys: ["${SSH_PUBKEY}"]
package_update: true
packages: [snmp, python3, jq, curl]
```

`lab/lab.env.example`:

```bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Copy to lab/lab.env (gitignored) and set real values. Example addresses use
# the RFC 5737 documentation range.
PVE_HOST=pve.example.net
PVE_SSH_USER=root
PVE_TEMPLATE_ID=9000
PVE_STORAGE=local-lvm
PVE_SNIPPET_STORAGE=local
PVE_SNIPPET_DIR=/var/lib/vz/snippets
PVE_BRIDGE=vmbr0
PVE_VLAN_TAG=
K8S_VMID=9101
K8S_IP=192.0.2.21/24
LOADGEN_VMID=9102
LOADGEN_IP=192.0.2.22/24
GATEWAY=192.0.2.1
DNS_SERVERS=192.0.2.53
K8S_MINOR=1.34
SSH_PUBKEY_FILE=~/.ssh/id_ed25519.pub
```

- [ ] **Step 6: Add Makefile targets**

Append to `Makefile`:

```make
LAB_ENV   := lab/lab.env
LAB_STATE := lab/.state
LAB_SSH    = ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$(LAB_STATE)/known_hosts

.PHONY: lab-up
lab-up:
	@test -f $(LAB_ENV) || { echo "Create $(LAB_ENV) from lab/lab.env.example"; exit 1; }
	@mkdir -p $(LAB_STATE)
	@source $(LAB_ENV); \
	  lab/scripts/pve-vm.sh create vpa-k8s $$K8S_VMID $$K8S_IP 16 49152 200 lab/cloud-init/k8s-user-data.yaml.tmpl; \
	  lab/scripts/pve-vm.sh create vpa-loadgen $$LOADGEN_VMID $$LOADGEN_IP 8 8192 40 lab/cloud-init/loadgen-user-data.yaml.tmpl; \
	  for ip in $${K8S_IP%/*} $${LOADGEN_IP%/*}; do \
	    until $(LAB_SSH) -o ConnectTimeout=5 lab@$$ip true 2>/dev/null; do sleep 10; done; \
	    $(LAB_SSH) lab@$$ip cloud-init status --wait; \
	  done
	@$(MAKE) --no-print-directory lab-kubeconfig

.PHONY: lab-kubeconfig
lab-kubeconfig:
	@source $(LAB_ENV); $(LAB_SSH) lab@$${K8S_IP%/*} cat .kube/config > $(LAB_STATE)/kubeconfig
	@chmod 600 $(LAB_STATE)/kubeconfig
	KUBECONFIG=$(LAB_STATE)/kubeconfig kubectl get nodes -o wide

.PHONY: lab-down
lab-down:
	@source $(LAB_ENV); \
	  lab/scripts/pve-vm.sh destroy vpa-loadgen $$LOADGEN_VMID; \
	  lab/scripts/pve-vm.sh destroy vpa-k8s $$K8S_VMID
	rm -rf $(LAB_STATE)
```

- [ ] **Step 7: Collect real lab values and write `lab/lab.env`**

Ask the operator for: two free VMIDs, two free addresses with prefix length, gateway, DNS servers, bridge and VLAN tag, target storage for VM disks, snippet storage. List what exists first so collisions are visible:

```bash
ssh root@"$PVE_HOST" 'qm list; pvesm status'
```

Write `lab/lab.env` from the example with those values. Confirm it is ignored: `git check-ignore lab/lab.env` prints the path.

- [ ] **Step 8: Bring the lab up**

Run: `make lab-up`
Expected: both VMs created and started. `cloud-init status --wait` ends with `status: done` for both. `kubectl get nodes -o wide` shows `vpa-k8s` with `VERSION v1.34.x`. Status is `NotReady` until the CNI lands in Task 11.

- [ ] **Step 9: Commit**

```bash
make test-scripts check-public
git add Makefile lab
git commit -s -m "feat(lab): provision kubeadm and load generator VMs on Proxmox

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 11: Cluster add-ons and VPA

**Files:**
- Create: `lab/scripts/cluster-addons.sh`
- Modify: `lab/lab.env.example` (add add-on versions)
- Modify: `Makefile` (target `lab-addons`)

**Interfaces:**
- Consumes: `lab/.state/kubeconfig` from Task 10.
- Produces: flannel, `local-path` as default StorageClass, metrics-server, VPA recommender/updater/admission-controller in `kube-system`. Updater and admission controller run with `--feature-gates=InPlaceOrRecreate=true`. Recommender runs with 1-hour aggregation and half-life.

- [ ] **Step 1: Pin and verify versions**

Add to `lab/lab.env.example` (and to your `lab/lab.env`):

```bash
FLANNEL_VERSION=v0.27.4
LOCAL_PATH_VERSION=v0.0.32
METRICS_SERVER_VERSION=v0.8.0
VPA_VERSION=1.5.1
```

Verify each tag exists before use:

```bash
source lab/lab.env
gh release view "$FLANNEL_VERSION" -R flannel-io/flannel --json tagName
gh release view "$LOCAL_PATH_VERSION" -R rancher/local-path-provisioner --json tagName
gh release view "$METRICS_SERVER_VERSION" -R kubernetes-sigs/metrics-server --json tagName
gh api "repos/kubernetes/autoscaler/git/refs/tags/vertical-pod-autoscaler-$VPA_VERSION" --jq .ref
```

Expected: four tag names. If one is missing, use the newest patch release of the same minor, and update both env files.

- [ ] **Step 2: Write** `lab/scripts/cluster-addons.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Install CNI, storage, metrics-server and upstream VPA with in-place resize.
# Idempotent: re-running re-applies the same manifests and flags.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "${LAB_ENV:-$here/../lab.env}"
export KUBECONFIG="${KUBECONFIG:-$here/../.state/kubeconfig}"
state="$here/../.state"

kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
kubectl wait --for=condition=Ready node --all --timeout=300s

kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kubeadm kubelets serve self-signed certificates.
kubectl -n kube-system get deploy metrics-server -o json \
  | jq '.spec.template.spec.containers[0].args |= ((. // []) - ["--kubelet-insecure-tls"] + ["--kubelet-insecure-tls"])' \
  | kubectl apply -f -
kubectl -n kube-system rollout status deploy/metrics-server --timeout=300s

src="$state/autoscaler"
if [[ ! -d "$src" ]]; then
  git clone --depth 1 --branch "vertical-pod-autoscaler-${VPA_VERSION}" https://github.com/kubernetes/autoscaler "$src"
fi
(cd "$src/vertical-pod-autoscaler" && TAG="$VPA_VERSION" ./hack/vpa-up.sh)

# add_args <deployment> <arg>...: append flags once, keeping the existing ones.
add_args() {
  local deploy="$1"; shift
  local json; json="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
  kubectl -n kube-system get deploy "$deploy" -o json \
    | jq --argjson a "$json" '.spec.template.spec.containers[0].args |= ((. // []) - $a + $a)' \
    | kubectl apply -f -
  kubectl -n kube-system rollout status "deploy/$deploy" --timeout=300s
}
add_args vpa-updater --feature-gates=InPlaceOrRecreate=true
add_args vpa-admission-controller --feature-gates=InPlaceOrRecreate=true
# Short history so a load step is reflected in hours instead of days.
add_args vpa-recommender \
  --memory-aggregation-interval=1h \
  --memory-aggregation-interval-count=8 \
  --memory-histogram-decay-half-life=1h \
  --cpu-histogram-decay-half-life=1h
```

Append to `Makefile`:

```make
.PHONY: lab-addons
lab-addons:
	lab/scripts/cluster-addons.sh
```

- [ ] **Step 3: Run it**

Run: `make lab-addons`
Expected: every `rollout status` reports `successfully rolled out`.

- [ ] **Step 4: Verify**

```bash
export KUBECONFIG=lab/.state/kubeconfig
kubectl get nodes
kubectl get storageclass
kubectl top nodes
kubectl api-resources | grep verticalpodautoscalers
for d in vpa-updater vpa-admission-controller vpa-recommender; do
  kubectl -n kube-system get deploy "$d" -o jsonpath='{.metadata.name}: {.spec.template.spec.containers[0].args}{"\n"}'
done
```

Expected: node `Ready`; `local-path (default)`; `kubectl top` shows CPU and memory; the VPA resource is listed; updater and admission controller args include `--feature-gates=InPlaceOrRecreate=true`; recommender args include the four `1h`/`8` flags.
If a VPA component crash-loops on the feature gate (the gate was removed after graduation), drop that flag, re-run, and note it in the commit message.

- [ ] **Step 5: Commit**

```bash
make test-scripts check-public
git add Makefile lab
git commit -s -m "feat(lab): install CNI, storage, metrics-server and VPA with in-place resize

The recommender runs with a one-hour history so load steps show up in
hours. Where recommender flags cannot be changed, the eight-day
default applies.

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 12: Phase 0 mechanism check

**Files:**
- Create: `lab/phase0/resize-check.sh`
- Create: `lab/phase0/lib.sh`
- Modify: `Makefile` (target `phase0-mechanism`)

**Interfaces:**
- Consumes: the cluster from Task 11.
- Produces: `lab/phase0/lib.sh` with `wait_for <timeout_s> <description> <command...>` and `pod_field <ns> <pod> <jsonpath>`, reused by Task 13. A pass or fail line per check. Exit 0 only when every check passes.

- [ ] **Step 1: Write** `lab/phase0/lib.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Shared helpers for Phase 0 checks.

# wait_for <timeout_s> <description> <command...>: poll every 5 s until the command succeeds.
wait_for() {
  local timeout="$1" what="$2"; shift 2
  local end=$(( $(date +%s) + timeout ))
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) > end )); then echo "timeout after ${timeout}s: $what" >&2; return 1; fi
    sleep 5
  done
}

# pod_field <ns> <pod> <jsonpath>
pod_field() { kubectl -n "$1" get pod "$2" -o jsonpath="$3"; }

# result <name> <0|1>: print and accumulate a check result in $FAILED.
# shellcheck disable=SC2034  # read by the scripts that source this file
FAILED=0
result() {
  if [[ "$2" == 0 ]]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi
}
```

- [ ] **Step 2: Write** `lab/phase0/resize-check.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0: in-place resize works on this cluster.
#  1. kubelet: CPU resize without restart, memory resize restarts the container, same pod.
#  2. VPA: InPlaceOrRecreate raises CPU on a busy single-replica Deployment without recreating the pod.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab/phase0/lib.sh
source "$here/lib.sh"
export KUBECONFIG="${KUBECONFIG:-$here/../.state/kubeconfig}"
ns=phase0

kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$ns" delete pod resize-probe --ignore-not-found --wait
kubectl -n "$ns" apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: resize-probe
spec:
  containers:
    - name: c
      image: busybox:1.37
      command: ["sleep", "86400"]
      resources:
        requests: {cpu: 100m, memory: 64Mi}
        limits: {memory: 64Mi}
      resizePolicy:
        - {resourceName: cpu, restartPolicy: NotRequired}
        - {resourceName: memory, restartPolicy: RestartContainer}
EOF
kubectl -n "$ns" wait --for=condition=Ready pod/resize-probe --timeout=120s

uid="$(pod_field "$ns" resize-probe '{.metadata.uid}')"
restarts() { pod_field "$ns" resize-probe '{.status.containerStatuses[0].restartCount}'; }
r0="$(restarts)"

kubectl -n "$ns" patch pod resize-probe --subresource resize \
  -p '{"spec":{"containers":[{"name":"c","resources":{"requests":{"cpu":"200m"}}}]}}'
cpu_applied() { [[ "$(pod_field "$ns" resize-probe '{.status.containerStatuses[0].resources.requests.cpu}')" == 200m ]]; }
wait_for 120 "CPU resize applied" cpu_applied && ok=0 || ok=1
[[ "$(restarts)" == "$r0" ]] || ok=1
result "kubelet: CPU resize in place, restartCount unchanged" "$ok"

kubectl -n "$ns" patch pod resize-probe --subresource resize \
  -p '{"spec":{"containers":[{"name":"c","resources":{"requests":{"memory":"128Mi"},"limits":{"memory":"128Mi"}}}]}}'
mem_applied() { [[ "$(pod_field "$ns" resize-probe '{.status.containerStatuses[0].resources.limits.memory}')" == 128Mi ]]; }
wait_for 180 "memory resize applied" mem_applied && ok=0 || ok=1
[[ "$(restarts)" == "$(( r0 + 1 ))" ]] || ok=1
[[ "$(pod_field "$ns" resize-probe '{.metadata.uid}')" == "$uid" ]] || ok=1
result "kubelet: memory resize restarts the container once, same pod UID" "$ok"

kubectl -n "$ns" delete deploy burner --ignore-not-found --wait
kubectl -n "$ns" apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: burner
spec:
  replicas: 1
  selector: {matchLabels: {app: burner}}
  template:
    metadata: {labels: {app: burner}}
    spec:
      containers:
        - name: c
          image: busybox:1.37
          command: ["sh", "-c", "while :; do :; done"]
          resources:
            requests: {cpu: 50m, memory: 32Mi}
            limits: {memory: 32Mi}
          resizePolicy:
            - {resourceName: cpu, restartPolicy: NotRequired}
            - {resourceName: memory, restartPolicy: RestartContainer}
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: burner
spec:
  targetRef: {apiVersion: apps/v1, kind: Deployment, name: burner}
  updatePolicy: {updateMode: InPlaceOrRecreate, minReplicas: 1}
  resourcePolicy:
    containerPolicies:
      - containerName: c
        controlledResources: [cpu]
        minAllowed: {cpu: 50m}
        maxAllowed: {cpu: "1"}
EOF
kubectl -n "$ns" rollout status deploy/burner --timeout=120s
pod="$(kubectl -n "$ns" get pod -l app=burner -o jsonpath='{.items[0].metadata.name}')"
buid="$(pod_field "$ns" "$pod" '{.metadata.uid}')"
cpu_raised() {
  local m; m="$(pod_field "$ns" "$pod" '{.status.containerStatuses[0].resources.requests.cpu}')"
  [[ "$m" != 50m ]]
}
wait_for 1200 "VPA raised burner CPU" cpu_raised && ok=0 || ok=1
[[ "$(pod_field "$ns" "$pod" '{.metadata.uid}')" == "$buid" ]] || ok=1
result "VPA: InPlaceOrRecreate raised CPU on a single replica without recreating the pod" "$ok"
kubectl -n "$ns" get vpa burner -o jsonpath='{.status.recommendation.containerRecommendations[0].target}{"\n"}'

kubectl delete namespace "$ns" --wait=false
exit "$FAILED"
```

Append to `Makefile`:

```make
.PHONY: phase0-mechanism
phase0-mechanism:
	lab/phase0/resize-check.sh
```

- [ ] **Step 3: Run it**

Run: `make phase0-mechanism`
Expected: three `PASS` lines, exit 0. The VPA check can take up to 20 minutes while the recommender builds history.
If the VPA check fails but the recommendation target is above 50m, inspect `kubectl -n kube-system logs deploy/vpa-updater | grep -i -E 'inplace|resize|burner'` and record the reason. That is a finding about VPA, not a script bug.

- [ ] **Step 4: Commit**

```bash
make test-scripts check-public
git add Makefile lab/phase0
git commit -s -m "test(lab): verify in-place resize on kubelet and through VPA

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

### Task 13: Deploy the stack, trap-to-alarm smoke test, JVM resize check

**Files:**
- Create: `lab/phase0/stack-check.sh`
- Create: `runs/phase0/.gitkeep`
- Modify: `Makefile` (targets `deploy`, `undeploy`, `phase0-stack`)

**Interfaces:**
- Consumes: the umbrella chart (Tasks 5 to 9), `lab/phase0/lib.sh` (Task 12), `LOADGEN_IP` and `K8S_IP` from `lab/lab.env`.
- Produces: release `poc` in namespace `poc`. `runs/phase0/<UTC timestamp>/results.json` with image versions, per-check results and before/after heap values. No IP addresses in the file.

- [ ] **Step 1: Add deploy targets** to `Makefile`

```make
KUBECONFIG_LAB := $(LAB_STATE)/kubeconfig

.PHONY: deploy
deploy: deps
	KUBECONFIG=$(KUBECONFIG_LAB) helm upgrade --install poc $(CHART) --namespace poc --create-namespace --wait --timeout 40m

.PHONY: undeploy
undeploy:
	KUBECONFIG=$(KUBECONFIG_LAB) helm uninstall poc --namespace poc --wait || true
	KUBECONFIG=$(KUBECONFIG_LAB) kubectl delete namespace poc --wait

.PHONY: phase0-stack
phase0-stack:
	lab/phase0/stack-check.sh
```

- [ ] **Step 2: Deploy**

Run: `make deploy`
Expected: `STATUS: deployed`. Then `KUBECONFIG=lab/.state/kubeconfig kubectl -n poc get pods` shows `postgresql-0`, `kafka-0`, `core-0` and `minion-0` all `Running` and ready.
If Core does not become ready within 40 minutes, collect `kubectl -n poc logs core-0 -c core --tail=200` and check for a daemon that failed to start because another was disabled. The spec's rule applies: re-enable that daemon in `values.yaml`, note which one and why in a comment, and re-deploy.

- [ ] **Step 3: Write** `lab/phase0/stack-check.sh`

```bash
#!/usr/bin/env bash
# Copyright 2026 Ronny Trommer <ronny@no42.org>
# SPDX-License-Identifier: Apache-2.0
#
# Phase 0 on the deployed stack:
#  1. Minion registers with Core.
#  2. A node is provisioned and an SNMPv2c trap from it becomes an alarm on that node.
#  3. Core CPU resizes in place without a restart.
#  4. A Minion memory resize restarts the container and the heap follows the new limit.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab/phase0/lib.sh
source "$here/lib.sh"
# shellcheck source=/dev/null
source "${LAB_ENV:-$here/../lab.env}"
export KUBECONFIG="${KUBECONFIG:-$here/../.state/kubeconfig}"
ns=poc
k8s_ip="${K8S_IP%/*}"
loadgen_ip="${LOADGEN_IP%/*}"
ssh_lab=(ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$here/../.state/known_hosts" "lab@${loadgen_ip}")
out="$here/../../runs/phase0/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"

kubectl -n "$ns" port-forward svc/core 18980:8980 >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null || true' EXIT
wait_for 60 "port-forward to Core" curl -sf -o /dev/null http://127.0.0.1:18980/opennms/login.jsp
rest() { curl -sf -u admin:admin -H 'Accept: application/json' "http://127.0.0.1:18980/opennms/rest/$1"; }

# 1. Minion registered and up.
minion_up() { rest minions | jq -e '.minion[]? | select(.location=="poc" and .status=="UP")'; }
wait_for 600 "Minion UP at location poc" minion_up && ok=0 || ok=1
result "Minion registered with Core at location poc" "$ok"
[[ "$ok" == 0 ]] || rest minions | jq . >&2 || true

# 2. Provision the load generator as a node, then send it a linkDown trap.
curl -sf -u admin:admin -H 'Content-Type: application/xml' -X POST \
  http://127.0.0.1:18980/opennms/rest/requisitions --data @- <<EOF
<model-import xmlns="http://xmlns.opennms.org/xsd/config/model-import" foreign-source="poc">
  <node foreign-id="loadgen" node-label="loadgen" location="poc">
    <interface ip-addr="${loadgen_ip}" snmp-primary="N"/>
  </node>
</model-import>
EOF
curl -sf -u admin:admin -X PUT "http://127.0.0.1:18980/opennms/rest/requisitions/poc/import?rescanExisting=false"
node_present() { rest "nodes?label=loadgen" | jq -e '.totalCount == 1'; }
wait_for 300 "node loadgen provisioned" node_present && ok=0 || ok=1
result "node loadgen provisioned from requisition" "$ok"

uei=uei.opennms.org/generic/traps/SNMP_Link_Down
alarm_on_node() { rest "alarms?uei=${uei}" | jq -e '.alarm[]? | select(.nodeLabel=="loadgen")'; }
sent=0
for _ in 1 2 3; do
  "${ssh_lab[@]}" snmptrap -v 2c -c public "${k8s_ip}:30162" '' .1.3.6.1.6.3.1.1.5.3 .1.3.6.1.2.1.2.2.1.1 i 1
  sent=$(( sent + 1 ))
  if wait_for 60 "linkDown alarm on loadgen" alarm_on_node; then break; fi
done
alarm_on_node && ok=0 || ok=1
result "SNMPv2c trap became an alarm on node loadgen (source address preserved)" "$ok"
[[ "$ok" == 0 ]] || rest "alarms?uei=${uei}" | jq '.alarm[]? | {nodeLabel, ipAddress}' >&2 || true

# 3. Core CPU in place.
c_restarts() { pod_field "$ns" core-0 '{.status.containerStatuses[?(@.name=="core")].restartCount}'; }
core_r0="$(c_restarts)"
kubectl -n "$ns" patch vpa core --type merge -p '{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
kubectl -n "$ns" patch pod core-0 --subresource resize \
  -p '{"spec":{"containers":[{"name":"core","resources":{"requests":{"cpu":"2"}}}]}}'
core_cpu() { [[ "$(pod_field "$ns" core-0 '{.status.containerStatuses[?(@.name=="core")].resources.requests.cpu}')" == 2 ]]; }
wait_for 120 "Core CPU resize applied" core_cpu && ok=0 || ok=1
[[ "$(c_restarts)" == "$core_r0" ]] || ok=1
result "Core CPU resized in place without restart" "$ok"

# 4. Minion memory resize: container restarts and -Xmx follows the limit.
xmx() {
  kubectl -n "$ns" exec minion-0 -c minion -- sh -c \
    'for p in /proc/[0-9]*; do tr "\0" " " < "$p/cmdline" 2>/dev/null; echo; done' \
    | grep -o -- '-Xmx[0-9]*m' | tail -1
}
m_restarts() { pod_field "$ns" minion-0 '{.status.containerStatuses[?(@.name=="minion")].restartCount}'; }
xmx_before="$(xmx)"
min_r0="$(m_restarts)"
kubectl -n "$ns" patch vpa minion --type merge -p '{"spec":{"updatePolicy":{"updateMode":"Off"}}}'
kubectl -n "$ns" patch pod minion-0 --subresource resize \
  -p '{"spec":{"containers":[{"name":"minion","resources":{"requests":{"memory":"2Gi"},"limits":{"memory":"2Gi"}}}]}}'
minion_restarted() { [[ "$(m_restarts)" == "$(( min_r0 + 1 ))" ]] && kubectl -n "$ns" wait --for=condition=Ready pod/minion-0 --timeout=5s; }
wait_for 600 "Minion restarted and ready" minion_restarted && ok=0 || ok=1
xmx_after="$(xmx || true)"
[[ "$xmx_after" == "-Xmx1228m" ]] || ok=1
result "Minion memory resize restarted the container and -Xmx followed (${xmx_before} -> ${xmx_after}, want -Xmx1228m)" "$ok"

jq -n \
  --arg core_image "$(pod_field "$ns" core-0 '{.spec.containers[?(@.name=="core")].image}')" \
  --arg minion_image "$(pod_field "$ns" minion-0 '{.spec.containers[?(@.name=="minion")].image}')" \
  --arg k8s "$(kubectl version -o json | jq -r .serverVersion.gitVersion)" \
  --arg xmx_before "$xmx_before" --arg xmx_after "$xmx_after" \
  --argjson traps_sent "$sent" --argjson failed "$FAILED" \
  '{phase: 0, kubernetes: $k8s, core_image: $core_image, minion_image: $minion_image,
    traps_sent: $traps_sent, minion_xmx_before: $xmx_before, minion_xmx_after: $xmx_after,
    passed: ($failed == 0)}' > "$out/results.json"
echo "wrote ${out#"$here/../../"}/results.json"
exit "$FAILED"
```

The expected `-Xmx1228m` is 2048 MiB × 60 % from `minion.heapFromCgroup.maxPercent`.
The script switches the Core and Minion VPAs to `Off` so they do not undo the manual resize. The next `make deploy` restores them from the chart.

- [ ] **Step 4: Run it**

Run: `touch runs/phase0/.gitkeep && make phase0-stack`
Expected: five `PASS` lines, exit 0, and `wrote runs/phase0/<timestamp>/results.json`.
If the alarm check fails while an alarm exists with an empty `nodeLabel`, the trap source was rewritten. Check `kubectl -n poc get svc minion-traps -o yaml` for `externalTrafficPolicy: Local`, and record it as a finding.

- [ ] **Step 5: Restore the VPAs, verify the record is clean, commit**

```bash
make deploy
make test check-public
grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}' runs/phase0/*/results.json && echo "IP found, remove before commit" || true
git add Makefile lab/phase0 runs/phase0
git commit -s -m "test(lab): deploy the stack and verify trap-to-alarm and JVM resize

Assisted-by: ClaudeCode:claude-opus-5-5
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Hand back**

Report the Phase 0 results and the path of `results.json`, and name any daemon re-enabled in Step 2 of this task.
Ask whether to push `opennms-vpa-poc` (run `make check-public` again right before the push).
The campaign plan (Phases 1 to 4 and report) starts from this state.

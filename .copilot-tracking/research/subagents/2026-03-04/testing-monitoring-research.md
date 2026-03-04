---
title: Testing and Monitoring Strategies for Zero-Downtime Kured Reboots on AKS
description: Comprehensive research on workload design, availability testing, monitoring, and proof artifacts for validating zero-downtime during Kured-managed node reboots
author: testing-monitoring-subagent
ms.date: 2026-03-04
ms.topic: reference
keywords:
  - kured
  - aks
  - zero-downtime
  - pod disruption budget
  - availability testing
  - container insights
  - prometheus metrics
estimated_reading_time: 25
---

## Overview

This document covers testing and monitoring strategies to prove zero-downtime during
Kured-managed node reboots on a 3-node AKS cluster. The research spans sample workload
design, PodDisruptionBudget configuration, availability testing approaches, Container
Insights KQL queries, Prometheus metric collection, end-to-end test scripting, and the
proof artifacts required to demonstrate zero request loss.

## Sample Workload Design

### Design Rationale

The ideal workload for demonstrating zero-downtime has these characteristics:

* Stateless HTTP service with deterministic response behavior
* Multiple replicas spread across nodes via anti-affinity rules
* A Kubernetes Service fronting the replicas so probes hit a stable endpoint
* A PodDisruptionBudget preventing all replicas from draining simultaneously
* Readiness and liveness probes so Kubernetes routes traffic only to healthy pods

A custom nginx-based deployment works well because it returns predictable HTTP 200
responses, starts quickly, and uses minimal resources.

### Deployment YAML

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zero-downtime-web
  namespace: demo
  labels:
    app: zero-downtime-web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: zero-downtime-web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: zero-downtime-web
    spec:
      terminationGracePeriodSeconds: 30
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchExpressions:
                    - key: app
                      operator: In
                      values:
                        - zero-downtime-web
                topologyKey: kubernetes.io/hostname
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
              name: http
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]
```

> [!NOTE]
> The `preStop` sleep of 5 seconds gives the Service time to remove the pod from its
> endpoint list before the container stops. This prevents in-flight requests from
> routing to a terminating pod.

### Service YAML

```yaml
apiVersion: v1
kind: Service
metadata:
  name: zero-downtime-web
  namespace: demo
  labels:
    app: zero-downtime-web
spec:
  type: LoadBalancer
  selector:
    app: zero-downtime-web
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
      name: http
```

A LoadBalancer Service provides an external IP for probing from outside the cluster.
For internal-only testing, use `ClusterIP` with port-forwarding or an Ingress
controller.

### Namespace

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
```

## PodDisruptionBudget Configuration

### How PDBs Interact with Kured

When Kured drains a node before rebooting, `kubectl drain` respects
PodDisruptionBudgets. The drain operation blocks until the PDB allows eviction.
Kured processes one node at a time by acquiring a lock via a ConfigMap or DaemonSet
annotation, so only one node drains concurrently.

### Recommended PDB Configuration

For a 3-replica deployment across 3 nodes, set `minAvailable: 2` (or equivalently
`maxUnavailable: 1`). This guarantees at least 2 replicas remain running while one
node drains.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: zero-downtime-web-pdb
  namespace: demo
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: zero-downtime-web
```

### PDB Behavior During Drain

| Scenario                     | Replicas running | PDB allows eviction? | Result                                 |
|------------------------------|------------------|----------------------|----------------------------------------|
| All 3 healthy, drain 1 node  | 3                | Yes                  | 1 evicted, 2 remain, rescheduled on 2  |
| 2 healthy (1 node rebooting) | 2                | No                   | Drain blocks until replica reschedules |
| 2 healthy, new replica ready | 3                | Yes                  | Next drain proceeds                    |

> [!IMPORTANT]
> If `minAvailable` equals the replica count (e.g., `minAvailable: 3` with 3
> replicas), the drain will block indefinitely. Always set `minAvailable` to at most
> `replicas - 1`.

### Alternative: maxUnavailable

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: zero-downtime-web-pdb
  namespace: demo
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: zero-downtime-web
```

Both `minAvailable: 2` and `maxUnavailable: 1` produce the same effect for 3
replicas. Use `maxUnavailable` when the replica count may scale dynamically, since it
adapts automatically.

## Availability Testing During Reboots

### Continuous HTTP Probe Approaches

Three options for continuous probing, in order of increasing sophistication:

#### Option 1: curl Loop (simplest)

A bash loop that sends HTTP requests every 0.5 seconds and logs timestamps, status
codes, and latency:

```bash
#!/bin/bash
# availability-probe.sh
# Usage: ./availability-probe.sh <SERVICE_IP> <DURATION_SECONDS>

SERVICE_URL="http://${1}/"
DURATION=${2:-600}
LOG_FILE="probe-results-$(date +%Y%m%d-%H%M%S).log"
FAIL_COUNT=0
TOTAL_COUNT=0
START_TIME=$(date +%s)

echo "Probing ${SERVICE_URL} for ${DURATION}s, logging to ${LOG_FILE}"
echo "timestamp,status_code,response_time_ms" > "${LOG_FILE}"

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))
  if [ "${ELAPSED}" -ge "${DURATION}" ]; then
    break
  fi

  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code},%{time_total}" \
    --connect-timeout 2 --max-time 5 "${SERVICE_URL}")
  STATUS_CODE=$(echo "${RESPONSE}" | cut -d',' -f1)
  TIME_MS=$(echo "${RESPONSE}" | cut -d',' -f2 | awk '{printf "%.0f", $1 * 1000}')

  echo "${TIMESTAMP},${STATUS_CODE},${TIME_MS}" >> "${LOG_FILE}"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))

  if [ "${STATUS_CODE}" != "200" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] ${TIMESTAMP} - HTTP ${STATUS_CODE} (${TIME_MS}ms)"
  fi

  sleep 0.5
done

echo ""
echo "=== Probe Summary ==="
echo "Total requests: ${TOTAL_COUNT}"
echo "Failed requests: ${FAIL_COUNT}"
echo "Success rate: $(echo "scale=4; (${TOTAL_COUNT} - ${FAIL_COUNT}) * 100 / ${TOTAL_COUNT}" | bc)%"
echo "Log file: ${LOG_FILE}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo "RESULT: ZERO-DOWNTIME VALIDATION FAILED"
  exit 1
else
  echo "RESULT: ZERO-DOWNTIME VALIDATED"
  exit 0
fi
```

#### Option 2: hey (HTTP benchmarking tool)

`hey` sends sustained load and reports latency distributions:

```bash
# Install hey
go install github.com/rakyll/hey@latest

# Run 10 requests/second for 10 minutes
hey -z 600s -q 10 -c 5 "http://<SERVICE_IP>/"
```

`hey` outputs a latency histogram and status code distribution. Any non-200 responses
appear in the summary. Redirect output to a file for proof artifacts.

#### Option 3: k6 Load Test (most detailed)

k6 provides scripted scenarios with custom thresholds:

```javascript
// k6-availability-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const failRate = new Rate('failed_requests');
const responseTrend = new Trend('response_time_ms');

export const options = {
  scenarios: {
    continuous_probe: {
      executor: 'constant-arrival-rate',
      rate: 2,
      timeUnit: '1s',
      duration: '15m',
      preAllocatedVUs: 5,
      maxVUs: 10,
    },
  },
  thresholds: {
    failed_requests: ['rate<0.001'],
    http_req_duration: ['p(99)<2000'],
  },
};

export default function () {
  const res = http.get(`http://${__ENV.SERVICE_IP}/`);
  const passed = check(res, {
    'status is 200': (r) => r.status === 200,
    'response time < 2s': (r) => r.timings.duration < 2000,
  });
  failRate.add(!passed);
  responseTrend.add(res.timings.duration);
  sleep(0.1);
}
```

Run with:

```bash
k6 run -e SERVICE_IP=<EXTERNAL_IP> k6-availability-test.js
```

### Triggering Reboots

#### Method 1: Create Sentinel File (recommended for POC)

Kured watches for `/var/run/reboot-required` (the file Ubuntu creates when a kernel
update needs a reboot). Create it manually on each node:

```bash
# Get node names
kubectl get nodes -o name

# For each node, create the sentinel file via a privileged pod
for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl debug node/"${NODE}" -it --image=busybox -- \
    sh -c "chroot /host touch /var/run/reboot-required"
  echo "Created reboot-required on ${NODE}"
done
```

Alternatively, use a DaemonSet to create the file on all nodes simultaneously:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: trigger-reboot
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: trigger-reboot
  template:
    metadata:
      labels:
        app: trigger-reboot
    spec:
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: trigger
          image: busybox:1.36
          command:
            - sh
            - -c
            - "chroot /host touch /var/run/reboot-required && sleep infinity"
          securityContext:
            privileged: true
          volumeMounts:
            - name: host-root
              mountPath: /host
      volumes:
        - name: host-root
          hostPath:
            path: /
```

> [!WARNING]
> Delete this DaemonSet after sentinel files are created. If left running, it will
> recreate the files on nodes after they reboot, causing an infinite reboot loop.

#### Method 2: Node Image Upgrade (production-like)

```bash
az aks nodepool upgrade \
  --resource-group <RG_NAME> \
  --cluster-name <CLUSTER_NAME> \
  --name <NODEPOOL_NAME> \
  --node-image-only
```

This triggers actual node image updates. Kured is not involved in this path; AKS
handles the rolling upgrade. Use this as a complementary test, not the primary Kured
validation.

#### Method 3: Scheduled Package Update (realistic)

SSH into nodes and install a kernel update that creates the sentinel file naturally:

```bash
kubectl debug node/<NODE_NAME> -it --image=ubuntu:22.04 -- \
  bash -c "chroot /host apt-get update && chroot /host apt-get install -y linux-generic"
```

### Recording Response Codes and Latency

All three probe approaches generate structured output:

| Tool  | Output format                          | Key metrics                           |
|-------|----------------------------------------|---------------------------------------|
| curl  | CSV (timestamp, status, latency)       | Per-request status and timing         |
| hey   | Text summary with histogram            | Latency percentiles, status breakdown |
| k6    | JSON/CSV with custom metrics           | Thresholds, trends, check pass rates  |

For the curl approach, generate a summary after the test:

```bash
# Count status codes from probe log
echo "=== Status Code Distribution ==="
tail -n +2 probe-results-*.log | cut -d',' -f2 | sort | uniq -c | sort -rn

# Find max latency
echo "=== Max Latency ==="
tail -n +2 probe-results-*.log | cut -d',' -f3 | sort -n | tail -1
```

## Monitoring with Container Insights

### Prerequisites

Enable Container Insights on the AKS cluster:

```bash
az aks enable-addons \
  --resource-group <RG_NAME> \
  --name <CLUSTER_NAME> \
  --addons monitoring \
  --workspace-resource-id <LOG_ANALYTICS_WORKSPACE_ID>
```

### KQL Queries

#### Node Ready/NotReady Transitions

Track when nodes transition between Ready and NotReady states during reboots:

```kql
KubeNodeInventory
| where TimeGenerated > ago(2h)
| where Status in ("Ready", "NotReady")
| project TimeGenerated, Computer, Status
| order by Computer asc, TimeGenerated asc
| serialize
| extend PrevStatus = prev(Status, 1, ""), PrevComputer = prev(Computer, 1, "")
| where Computer == PrevComputer and Status != PrevStatus
| project TimeGenerated, Computer, PreviousStatus = PrevStatus, NewStatus = Status
| order by TimeGenerated asc
```

#### Pod Restart Count During Test Window

```kql
KubePodInventory
| where TimeGenerated > ago(2h)
| where Namespace == "demo"
| where Name startswith "zero-downtime-web"
| summarize MaxRestarts = max(PodRestartCount) by Name, bin(TimeGenerated, 1m)
| order by TimeGenerated asc
```

#### Pod Eviction and Rescheduling Timeline

```kql
KubeEvents
| where TimeGenerated > ago(2h)
| where Namespace == "demo"
| where Reason in ("Killing", "Scheduled", "Pulled", "Created", "Started", "Evicted")
| project TimeGenerated, Name, Reason, Message
| order by TimeGenerated asc
```

#### Kured Reboot Events from DaemonSet Logs

```kql
ContainerLogV2
| where TimeGenerated > ago(2h)
| where PodName startswith "kured-"
| where PodNamespace == "kube-system"
| where LogMessage has_any ("reboot", "drain", "uncordon", "lock", "release")
| project TimeGenerated, PodName, LogMessage
| order by TimeGenerated asc
```

> [!NOTE]
> If using ContainerLog (v1 schema), replace `LogMessage` with `LogEntry` and
> `PodName`/`PodNamespace` with the appropriate v1 fields.

#### Node Drain Timeline

```kql
KubeEvents
| where TimeGenerated > ago(2h)
| where Reason in ("DrainStarted", "DrainSucceeded", "DrainFailed",
    "NodeNotReady", "NodeReady")
| project TimeGenerated, ObjectKind, Name, Reason, Message
| order by TimeGenerated asc
```

#### Service Endpoint Changes

```kql
KubeEvents
| where TimeGenerated > ago(2h)
| where ObjectKind == "Endpoints"
| where Name == "zero-downtime-web"
| where Namespace == "demo"
| project TimeGenerated, Reason, Message
| order by TimeGenerated asc
```

### Checking Kured DaemonSet Logs Directly

Use `kubectl` for real-time log monitoring:

```bash
# Follow Kured logs across all pods
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --follow --prefix

# Check Kured reboot history
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --since=2h | \
  grep -iE "reboot|drain|uncordon|lock|release"
```

### Dashboard or Workbook Visualization

Create an Azure Monitor Workbook with these panels:

1. Node Status Timeline: `KubeNodeInventory` plotted as a time chart with Status as
   the series. Shows Ready/NotReady transitions per node.
2. Pod Lifecycle Events: `KubeEvents` filtered to the demo namespace, displayed as a
   time-scatter plot showing eviction and scheduling events.
3. Kured Activity Log: The `ContainerLogV2` query above rendered as a text grid
   showing the reboot sequence.
4. Availability Probe Results: Import the curl CSV or k6 metrics into a custom table
   and plot response codes over time.

Workbook template (ARM/Bicep) structure:

```json
{
  "version": "Notebook/1.0",
  "items": [
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "KubeNodeInventory | where TimeGenerated > ago(2h) | summarize count() by Status, bin(TimeGenerated, 1m) | render timechart",
        "size": 0,
        "title": "Node Status Over Time",
        "timeContext": { "durationMs": 7200000 },
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces"
      }
    },
    {
      "type": 3,
      "content": {
        "version": "KqlItem/1.0",
        "query": "ContainerLogV2 | where TimeGenerated > ago(2h) | where PodName startswith 'kured-' | where LogMessage has_any ('reboot','drain','uncordon') | project TimeGenerated, PodName, LogMessage | order by TimeGenerated asc",
        "size": 0,
        "title": "Kured Reboot Activity",
        "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces"
      }
    }
  ]
}
```

## Prometheus Metrics from Kured

### Metrics Exposed by Kured

Kured exposes Prometheus metrics on port 8080 (configurable) at `/metrics`:

| Metric                       | Type    | Description                                    |
|------------------------------|---------|------------------------------------------------|
| `kured_reboot_required`      | Gauge   | 1 if the node requires a reboot, 0 otherwise   |
| `kured_drain_blocked_by_pdb` | Counter | Increments when a drain is blocked by a PDB    |
| `kured_reboot_count`         | Counter | Total reboots performed by this Kured instance |

### Enabling Prometheus Metrics in Kured Helm Values

```yaml
# kured-values.yaml
configuration:
  period: "1m"
  rebootSentinel: "/var/run/reboot-required"
  prometheusUrl: "http://0.0.0.0:8080"

metrics:
  create: true
  labels: {}
  annotations: {}

service:
  create: true
  port: 8080
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "8080"
```

### Scraping with Azure Monitor Managed Prometheus

If using Azure Monitor managed Prometheus (enabled via AKS monitoring addon), create a
PodMonitor:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: kured-metrics
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: kured
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 30s
```

### Scraping with Self-Hosted Prometheus

Add a scrape config to your Prometheus configuration:

```yaml
scrape_configs:
  - job_name: kured
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names:
            - kube-system
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
        regex: kured
        action: keep
      - source_labels: [__meta_kubernetes_pod_container_port_number]
        regex: "8080"
        action: keep
```

### Grafana Dashboard Panels

Create a Grafana dashboard with PromQL queries:

```text
Panel 1: Nodes Requiring Reboot
  Query: kured_reboot_required
  Visualization: Stat (sum)

Panel 2: Reboot Count Over Time
  Query: increase(kured_reboot_count[1h])
  Visualization: Time series

Panel 3: PDB-Blocked Drains
  Query: increase(kured_drain_blocked_by_pdb[1h])
  Visualization: Time series

Panel 4: Reboot Required per Node
  Query: kured_reboot_required
  Legend: {{node}}
  Visualization: Time series (one line per node)
```

### Alert Rules

```yaml
groups:
  - name: kured-alerts
    rules:
      - alert: KuredRebootPending
        expr: kured_reboot_required == 1
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.node }} has a pending reboot for over 30 minutes"
      - alert: KuredDrainBlockedByPDB
        expr: increase(kured_drain_blocked_by_pdb[10m]) > 3
        labels:
          severity: critical
        annotations:
          summary: "Kured drain blocked by PDB on {{ $labels.node }} repeatedly"
```

## End-to-End Test Script

This script orchestrates the full zero-downtime validation:

```bash
#!/bin/bash
# e2e-zero-downtime-test.sh
# End-to-end test: validates zero-downtime during Kured-managed node reboots
#
# Prerequisites:
#   - kubectl configured for the target AKS cluster
#   - Sample workload deployed (zero-downtime-web in demo namespace)
#   - Kured installed and running
#   - curl, jq available
#
# Usage: ./e2e-zero-downtime-test.sh

set -euo pipefail

# Configuration
NAMESPACE="demo"
SERVICE_NAME="zero-downtime-web"
PROBE_DURATION=900        # 15 minutes
PROBE_INTERVAL=0.5        # seconds between probes
KURED_SETTLE_TIME=60      # seconds to wait after creating sentinel files
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="test-results/${TIMESTAMP}"
PROBE_LOG="${RESULTS_DIR}/probe-results.csv"
NODE_LOG="${RESULTS_DIR}/node-status.log"
KURED_LOG="${RESULTS_DIR}/kured-activity.log"
SUMMARY_FILE="${RESULTS_DIR}/test-summary.txt"

mkdir -p "${RESULTS_DIR}"

echo "========================================"
echo " Zero-Downtime Reboot Validation Test"
echo " Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================"

# --- Step 1: Validate prerequisites ---
echo ""
echo "[Step 1] Validating prerequisites..."

# Check namespace and deployment exist
kubectl get namespace "${NAMESPACE}" > /dev/null 2>&1 || {
  echo "ERROR: Namespace '${NAMESPACE}' not found"; exit 1
}
kubectl get deployment "${SERVICE_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1 || {
  echo "ERROR: Deployment '${SERVICE_NAME}' not found"; exit 1
}

# Check PDB exists
kubectl get pdb -n "${NAMESPACE}" -l app="${SERVICE_NAME}" > /dev/null 2>&1 || {
  echo "WARNING: No PDB found for app=${SERVICE_NAME}"
}

# Check Kured is running
KURED_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=kured \
  --field-selector=status.phase=Running -o name | wc -l)
if [ "${KURED_PODS}" -eq 0 ]; then
  echo "ERROR: No running Kured pods found"; exit 1
fi
echo "  Found ${KURED_PODS} running Kured pods"

# Get Service external IP
SERVICE_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
if [ -z "${SERVICE_IP}" ]; then
  echo "ERROR: Service has no external IP. Waiting up to 120s..."
  kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    svc/"${SERVICE_NAME}" -n "${NAMESPACE}" --timeout=120s
  SERVICE_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
fi
echo "  Service IP: ${SERVICE_IP}"

# Verify service is reachable
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
  "http://${SERVICE_IP}/")
if [ "${HTTP_STATUS}" != "200" ]; then
  echo "ERROR: Service returned HTTP ${HTTP_STATUS}, expected 200"; exit 1
fi
echo "  Service is healthy (HTTP 200)"

# Record initial node status
echo "[Step 1] Initial node status:"
kubectl get nodes -o wide | tee "${NODE_LOG}"

# Record initial pod distribution
echo ""
echo "[Step 1] Pod distribution across nodes:"
kubectl get pods -n "${NAMESPACE}" -l app="${SERVICE_NAME}" -o wide

echo ""
echo "[Step 1] Prerequisites validated."

# --- Step 2: Start continuous availability probe (background) ---
echo ""
echo "[Step 2] Starting continuous availability probe..."
echo "timestamp,status_code,response_time_ms" > "${PROBE_LOG}"

probe_running=true
(
  START=$(date +%s)
  while [ $(($(date +%s) - START)) -lt "${PROBE_DURATION}" ]; do
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    RESP=$(curl -s -o /dev/null -w "%{http_code},%{time_total}" \
      --connect-timeout 2 --max-time 5 "http://${SERVICE_IP}/" 2>/dev/null || echo "000,0")
    CODE=$(echo "${RESP}" | cut -d',' -f1)
    TIME_MS=$(echo "${RESP}" | cut -d',' -f2 | awk '{printf "%.0f", $1 * 1000}')
    echo "${TS},${CODE},${TIME_MS}" >> "${PROBE_LOG}"
    sleep "${PROBE_INTERVAL}"
  done
) &
PROBE_PID=$!
echo "  Probe PID: ${PROBE_PID}"
echo "  Logging to: ${PROBE_LOG}"

# --- Step 3: Capture Kured logs (background) ---
echo ""
echo "[Step 3] Starting Kured log capture..."
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --follow --prefix \
  > "${KURED_LOG}" 2>&1 &
KURED_LOG_PID=$!
echo "  Kured log PID: ${KURED_LOG_PID}"

# --- Step 4: Trigger reboots on all nodes ---
echo ""
echo "[Step 4] Creating reboot sentinel files on all nodes..."

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for NODE in ${NODES}; do
  echo "  Creating /var/run/reboot-required on ${NODE}..."
  kubectl debug "node/${NODE}" -it --image=busybox:1.36 -- \
    sh -c "chroot /host touch /var/run/reboot-required" 2>/dev/null || true
done

echo "  Sentinel files created. Kured will process reboots one at a time."
echo "  Waiting ${KURED_SETTLE_TIME}s for Kured to detect sentinel files..."
sleep "${KURED_SETTLE_TIME}"

# --- Step 5: Monitor node status transitions ---
echo ""
echo "[Step 5] Monitoring node status during reboot cycle..."
echo "  (Checking every 30s until all nodes are Ready or timeout)"

MAX_WAIT=840   # 14 minutes max
ELAPSED=0
ALL_READY=false

while [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
  NOT_READY=$(kubectl get nodes --no-headers | grep -c "NotReady" || true)
  READY=$(kubectl get nodes --no-headers | grep -c " Ready" || true)
  REBOOTS_PENDING=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' | \
    xargs -I{} kubectl debug "node/{}" --image=busybox:1.36 -- \
    sh -c "[ -f /host/var/run/reboot-required ] && echo pending || echo done" 2>/dev/null | \
    grep -c "pending" || true)

  echo "  [+${ELAPSED}s] Ready: ${READY}, NotReady: ${NOT_READY}"

  # Append to node log
  echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "${NODE_LOG}"
  kubectl get nodes -o wide >> "${NODE_LOG}" 2>&1

  if [ "${NOT_READY}" -eq 0 ] && [ "${ELAPSED}" -gt 120 ]; then
    # All nodes ready and we have waited enough for at least one reboot cycle
    ALL_READY=true
    echo "  All nodes are Ready."
    break
  fi

  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

if [ "${ALL_READY}" != "true" ]; then
  echo "  WARNING: Not all nodes returned to Ready within ${MAX_WAIT}s"
fi

# --- Step 6: Wait for probe to complete ---
echo ""
echo "[Step 6] Waiting for availability probe to complete..."
wait "${PROBE_PID}" 2>/dev/null || true

# Stop Kured log capture
kill "${KURED_LOG_PID}" 2>/dev/null || true

# --- Step 7: Analyze results ---
echo ""
echo "[Step 7] Analyzing probe results..."

TOTAL=$(tail -n +2 "${PROBE_LOG}" | wc -l)
FAILURES=$(tail -n +2 "${PROBE_LOG}" | cut -d',' -f2 | grep -cv "200" || true)
SUCCESS_RATE=$(echo "scale=4; (${TOTAL} - ${FAILURES}) * 100 / ${TOTAL}" | bc)
MAX_LATENCY=$(tail -n +2 "${PROBE_LOG}" | cut -d',' -f3 | sort -n | tail -1)
AVG_LATENCY=$(tail -n +2 "${PROBE_LOG}" | cut -d',' -f3 | \
  awk '{ sum += $1; n++ } END { if (n>0) printf "%.0f", sum/n; else print 0 }')

# Status code distribution
echo "  Status code distribution:"
tail -n +2 "${PROBE_LOG}" | cut -d',' -f2 | sort | uniq -c | sort -rn | \
  while read -r COUNT CODE; do
    echo "    HTTP ${CODE}: ${COUNT} requests"
  done

# Write summary
{
  echo "=== Zero-Downtime Reboot Test Summary ==="
  echo "Test run: ${TIMESTAMP}"
  echo "Service: ${SERVICE_NAME} (${SERVICE_IP})"
  echo "Probe duration: ${PROBE_DURATION}s"
  echo "Total requests: ${TOTAL}"
  echo "Failed requests: ${FAILURES}"
  echo "Success rate: ${SUCCESS_RATE}%"
  echo "Average latency: ${AVG_LATENCY}ms"
  echo "Max latency: ${MAX_LATENCY}ms"
  echo ""
  if [ "${FAILURES}" -eq 0 ]; then
    echo "RESULT: ZERO-DOWNTIME VALIDATED"
  else
    echo "RESULT: ZERO-DOWNTIME VALIDATION FAILED"
    echo ""
    echo "Failed request details:"
    tail -n +2 "${PROBE_LOG}" | awk -F',' '$2 != "200" { print $0 }'
  fi
} | tee "${SUMMARY_FILE}"

# --- Step 8: Collect final state ---
echo ""
echo "[Step 8] Collecting final cluster state..."
echo "--- Final Node Status ---" >> "${NODE_LOG}"
kubectl get nodes -o wide >> "${NODE_LOG}"

echo ""
echo "=== Test Artifacts ==="
echo "  Probe log:     ${PROBE_LOG}"
echo "  Node log:      ${NODE_LOG}"
echo "  Kured log:     ${KURED_LOG}"
echo "  Test summary:  ${SUMMARY_FILE}"
echo ""

# Exit with appropriate code
if [ "${FAILURES}" -eq 0 ]; then
  echo "TEST PASSED: Zero-downtime validated during Kured-managed reboots."
  exit 0
else
  echo "TEST FAILED: ${FAILURES} requests failed during reboot cycle."
  exit 1
fi
```

### PowerShell Equivalent (for Windows-based CI)

```powershell
# Invoke-ZeroDowntimeTest.ps1
# Run the availability probe from a Windows machine or GitHub Actions runner

param(
    [Parameter(Mandatory)][string]$ServiceIP,
    [int]$DurationSeconds = 600,
    [double]$IntervalSeconds = 0.5
)

$logFile = "probe-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
"timestamp,status_code,response_time_ms" | Out-File -FilePath $logFile

$startTime = Get-Date
$failCount = 0
$totalCount = 0

Write-Host "Probing http://$ServiceIP/ for ${DurationSeconds}s..."

while ((Get-Date) -lt $startTime.AddSeconds($DurationSeconds)) {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $response = Invoke-WebRequest -Uri "http://$ServiceIP/" `
            -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        $statusCode = $response.StatusCode
        $latencyMs = $sw.ElapsedMilliseconds
    }
    catch {
        $sw.Stop()
        $statusCode = 0
        $latencyMs = $sw.ElapsedMilliseconds
        $failCount++
    }

    "$timestamp,$statusCode,$latencyMs" | Out-File -FilePath $logFile -Append
    $totalCount++

    if ($statusCode -ne 200) {
        Write-Host "[FAIL] $timestamp - HTTP $statusCode (${latencyMs}ms)" -ForegroundColor Red
    }

    Start-Sleep -Milliseconds ([int]($IntervalSeconds * 1000))
}

$successRate = if ($totalCount -gt 0) {
    [math]::Round(($totalCount - $failCount) / $totalCount * 100, 4)
} else { 0 }

Write-Host "`n=== Probe Summary ==="
Write-Host "Total requests: $totalCount"
Write-Host "Failed requests: $failCount"
Write-Host "Success rate: $successRate%"

if ($failCount -eq 0) {
    Write-Host "RESULT: ZERO-DOWNTIME VALIDATED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "RESULT: ZERO-DOWNTIME VALIDATION FAILED" -ForegroundColor Red
    exit 1
}
```

## Proof Artifacts

Collect the following artifacts to demonstrate zero-downtime:

### Required Artifacts

| Artifact                      | Source                      | Proves                                           |
|-------------------------------|-----------------------------|--------------------------------------------------|
| Probe results CSV             | curl loop / k6 / hey output | No HTTP failures during entire reboot cycle      |
| Test summary                  | e2e test script output      | Pass/fail verdict with request counts            |
| Node status timeline log      | kubectl get nodes snapshots | Nodes transitioned NotReady then back to Ready   |
| Kured DaemonSet logs          | kubectl logs                | Kured drained, rebooted, and uncordoned nodes    |
| KQL: node transitions         | Container Insights query    | Timestamped Ready/NotReady transitions           |
| KQL: pod events               | Container Insights query    | Pod eviction and rescheduling during reboot      |
| KQL: Kured log entries        | ContainerLogV2 query        | Kured lock acquire, drain, reboot, uncordon flow |
| PDB status during drain       | kubectl get pdb snapshots   | PDB blocked concurrent evictions                 |
| Pod distribution before/after | kubectl get pods -o wide    | Pods redistributed after reboots                 |

### Optional (Enhanced) Artifacts

| Artifact                          | Source                       | Proves                                    |
|-----------------------------------|------------------------------|-------------------------------------------|
| Prometheus metrics snapshot       | Grafana screenshot or export | kured_reboot_required transitions         |
| k6 HTML report                    | k6 --out json + report       | Latency distribution and threshold checks |
| Azure Monitor Workbook screenshot | Azure Portal                 | Visual timeline of the full reboot cycle  |
| GitHub Actions workflow log       | CI run                       | Automated test passed in CI pipeline      |

### Artifact Collection Script

```bash
#!/bin/bash
# collect-proof-artifacts.sh
# Collects all proof artifacts after a zero-downtime test

ARTIFACTS_DIR="proof-artifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${ARTIFACTS_DIR}"

echo "Collecting proof artifacts to ${ARTIFACTS_DIR}..."

# Cluster state
kubectl get nodes -o wide > "${ARTIFACTS_DIR}/nodes.txt"
kubectl get pods -n demo -o wide > "${ARTIFACTS_DIR}/pods.txt"
kubectl get pdb -n demo -o yaml > "${ARTIFACTS_DIR}/pdb.yaml"
kubectl get events -n demo --sort-by='.lastTimestamp' > "${ARTIFACTS_DIR}/events.txt"

# Kured logs
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --since=2h \
  > "${ARTIFACTS_DIR}/kured-logs.txt"

# Kured DaemonSet status
kubectl get ds -n kube-system kured -o yaml > "${ARTIFACTS_DIR}/kured-daemonset.yaml"

# Node descriptions (for conditions timeline)
for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl describe node "${NODE}" > "${ARTIFACTS_DIR}/node-${NODE}-describe.txt"
done

# PDB status
kubectl get pdb -n demo -o wide > "${ARTIFACTS_DIR}/pdb-status.txt"

echo "Artifacts collected in ${ARTIFACTS_DIR}"
ls -la "${ARTIFACTS_DIR}"
```

## Remaining Questions

* Kured lock mechanism: Kured uses a DaemonSet annotation-based lock by default. If
  the cluster runs multiple node pools, verify that Kured instances across pools
  coordinate using the same lock. Consider using `--lock-release-delay` to add a
  buffer between consecutive reboots.
* Kured reboot window: If a reboot window is configured (e.g., only reboot between
  01:00-05:00 UTC), the e2e test must either run within that window or temporarily
  disable the window for testing. The Helm value `configuration.startTime` and
  `configuration.endTime` control this.
* Container Insights ingestion delay: KQL queries against `ContainerLogV2` may have a
  2-5 minute ingestion lag. Schedule artifact collection queries at least 10 minutes
  after the test completes.
* k6 vs. curl for CI: curl loops are simpler for CI integration. k6 provides richer
  analytics but requires installing the k6 binary. For GitHub Actions, the
  `grafana/k6-action` action simplifies k6 execution.
* Network policy impact: If NetworkPolicies restrict traffic to the Service, ensure
  the probe source (CI runner or external IP) is allowed.
* AKS surge settings: The default node pool surge setting (`maxSurge`) does not apply
  to Kured-initiated reboots (Kured drains in-place). However, confirm that no
  cluster autoscaler rules interfere with pod rescheduling during drain operations.

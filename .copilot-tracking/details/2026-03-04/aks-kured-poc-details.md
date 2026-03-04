<!-- markdownlint-disable-file -->
# Implementation Details: AKS Kured Zero-Downtime Node Reboot POC

## Context Reference

Sources:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 1-659) — Primary research with complete code examples
- [aks-bicep-deployment-research.md](../../research/subagents/2026-03-04/aks-bicep-deployment-research.md) (Lines 1-615) — AKS Bicep definitions
- [kured-configuration-research.md](../../research/subagents/2026-03-04/kured-configuration-research.md) (Lines 1-513) — Kured Helm config
- [github-actions-workflows-research.md](../../research/subagents/2026-03-04/github-actions-workflows-research.md) (Lines 1-1061) — Complete workflow YAML
- [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) (Lines 1-1121) — Test scripts, KQL, proof artifacts

## Implementation Phase 1: Infrastructure as Code (Bicep)

<!-- parallelizable: true -->

### Step 1.1: Create `infra/main.bicep` with AKS cluster definition

Create the Bicep template that deploys a Log Analytics Workspace and an AKS cluster with 3 Ubuntu Linux nodes, SystemAssigned identity, Container Insights, and the critical `nodeOSUpgradeChannel: 'Unmanaged'` setting.

Use the complete Bicep template from the primary research document (Lines 197-290). Key elements:

- Resource: `Microsoft.ContainerService/managedClusters@2024-09-01`
- Identity: `SystemAssigned`
- Agent pool: `systempool`, 3 nodes, `Standard_DS2_v2`, `osSKU: 'Ubuntu'`, `osDiskType: 'Ephemeral'`
- Network: `kubenet` with `standard` load balancer
- Addons: `omsagent` for Container Insights linked to Log Analytics workspace
- Auto-upgrade: `upgradeChannel: 'patch'`, `nodeOSUpgradeChannel: 'Unmanaged'` (critical for Kured)
- Outputs: `controlPlaneFqdn`, `clusterName`, `clusterResourceId`, `nodeResourceGroup`, `kubeletIdentityObjectId`, `logAnalyticsWorkspaceId`

Parameters to define:
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `location` | string | `resourceGroup().location` | Azure region |
| `clusterName` | string | (required) | AKS cluster name |
| `dnsPrefix` | string | `clusterName` | DNS prefix |
| `kubernetesVersion` | string | `''` (latest stable) | K8s version |
| `nodeCount` | int | `3` | Node count (1-10) |
| `vmSize` | string | `'Standard_DS2_v2'` | VM SKU |
| `osDiskSizeGB` | int | `30` | OS disk size |
| `logAnalyticsWorkspaceName` | string | `'${clusterName}-logs'` | Log Analytics name |
| `logRetentionDays` | int | `30` | Retention (30-365) |
| `tags` | object | `{project:'aks-kured-poc',environment:'poc'}` | Resource tags |

Files:
- `infra/main.bicep` - New file, AKS cluster Bicep template

Discrepancy references:
- None — aligns with research recommendation

Success criteria:
- `az bicep build --file infra/main.bicep` succeeds with no errors
- Template defines all parameters, resources, and outputs listed above

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 197-290) — Complete Bicep template
- [aks-bicep-deployment-research.md](../../research/subagents/2026-03-04/aks-bicep-deployment-research.md) (Lines 28-80) — AKS resource properties reference

Dependencies:
- None (first step)

### Step 1.2: Create `infra/parameters.json` with default parameter values

Create the Bicep parameters file with POC defaults.

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "clusterName": { "value": "aks-kured-poc" },
    "nodeCount": { "value": 3 },
    "vmSize": { "value": "Standard_DS2_v2" },
    "osDiskSizeGB": { "value": 30 },
    "logRetentionDays": { "value": 30 },
    "tags": {
      "value": {
        "project": "aks-kured-poc",
        "environment": "poc",
        "managedBy": "bicep"
      }
    }
  }
}
```

Files:
- `infra/parameters.json` - New file, Bicep deployment parameters

Success criteria:
- Valid JSON schema matching `deploymentParameters.json` format
- All parameter names match `main.bicep` declarations

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 292-315) — Parameters JSON

Dependencies:
- Step 1.1 for parameter name alignment

### Step 1.3: Validate Bicep compilation

Run `az bicep build --file infra/main.bicep` to confirm the template compiles without errors. Fix any type or syntax issues.

Validation commands:
- `az bicep build --file infra/main.bicep` — Bicep compilation check

## Implementation Phase 2: Kubernetes Manifests (Workload + Kured)

<!-- parallelizable: true -->

### Step 2.1: Create `k8s/workload/namespace.yaml` for demo namespace

Create a simple namespace manifest for the demo workload.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
```

Files:
- `k8s/workload/namespace.yaml` - New file, namespace definition

Success criteria:
- Valid Kubernetes namespace manifest
- Name is `demo`

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 395-400) — Namespace YAML

Dependencies:
- None

### Step 2.2: Create `k8s/workload/deployment.yaml` with 3-replica nginx, anti-affinity, preStop hook

Create the deployment manifest for a 3-replica nginx workload designed for zero-downtime. Key configuration elements:

- **Image**: `nginx:1.27-alpine` (small, fast startup)
- **Replicas**: 3 (one per node)
- **Strategy**: `RollingUpdate` with `maxSurge: 1`, `maxUnavailable: 0`
- **Pod anti-affinity**: `preferredDuringSchedulingIgnoredDuringExecution` on `kubernetes.io/hostname` to spread across nodes
- **Probes**: readiness (HTTP GET /, 2s initial, 5s period) and liveness (HTTP GET /, 5s initial, 10s period)
- **Resources**: requests `50m/64Mi`, limits `100m/128Mi`
- **preStop hook**: `sleep 5` — gives the Service time to remove the pod from endpoints before termination
- **terminationGracePeriodSeconds**: 30

Files:
- `k8s/workload/deployment.yaml` - New file, deployment manifest

Discrepancy references:
- None — matches research recommendation exactly

Success criteria:
- Valid Kubernetes Deployment manifest
- Anti-affinity rule targets `kubernetes.io/hostname`
- preStop lifecycle hook present with `sleep 5`
- Readiness and liveness probes configured

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 402-467) — Complete deployment YAML
- [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) (Lines 46-112) — Workload design rationale

Dependencies:
- Step 2.1 (namespace must exist)

### Step 2.3: Create `k8s/workload/service.yaml` with LoadBalancer type

Create a LoadBalancer Service to expose the workload externally for availability probing.

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

Files:
- `k8s/workload/service.yaml` - New file, LoadBalancer service

Success criteria:
- Service type is `LoadBalancer`
- Selector matches deployment label `app: zero-downtime-web`

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 469-485) — Service YAML

Dependencies:
- Step 2.2 (for label alignment)

### Step 2.4: Create `k8s/workload/pdb.yaml` with `minAvailable: 2`

Create the PodDisruptionBudget that ensures at least 2 replicas remain running during node drains.

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

Why `minAvailable: 2`: With 3 replicas, this allows Kured to drain one node at a time (evicting 1 pod) while 2 remain serving traffic. The drain blocks if fewer than 2 would remain.

Files:
- `k8s/workload/pdb.yaml` - New file, PodDisruptionBudget

Discrepancy references:
- None — `minAvailable: 2` aligns with research for 3-replica workload

Success criteria:
- PDB `minAvailable` set to 2
- Selector matches deployment label

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 487-500) — PDB YAML
- [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) (Lines 145-195) — PDB behavior during drain

Dependencies:
- Step 2.2 (for label alignment)

### Step 2.5: Create `k8s/kured-values.yaml` with disruption window and drain settings

Create the Kured Helm values file. Key configuration:

- **Reboot window**: Weekdays (mo-fr), 2 AM–6 AM UTC
- **Poll period**: `1m` (frequent for POC demo, production typically 60m)
- **Drain**: `drainGracePeriod: 60`, `drainTimeout: 300s`
- **Lock**: `lockTtl: 30m`, `lockReleaseDelay: 5m`, `concurrency: 1`
- **Annotations**: `annotateNodes: true` for visibility
- **Metrics**: enabled for Prometheus scraping
- **Resources**: requests `10m/32Mi`, limits `50m/64Mi`
- **Node selector**: `kubernetes.io/os: linux`

```yaml
configuration:
  rebootDays: [mo, tu, we, th, fr]
  startTime: "2am"
  endTime: "6am"
  timeZone: "UTC"
  period: "1m"
  drainGracePeriod: "60"
  drainTimeout: "300s"
  lockTtl: "30m"
  lockReleaseDelay: "5m"
  annotateNodes: true
  concurrency: 1
  logFormat: "text"

metrics:
  create: true

service:
  create: true
  port: 8080

nodeSelector:
  kubernetes.io/os: linux

resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 50m
    memory: 64Mi
```

Files:
- `k8s/kured-values.yaml` - New file, Kured Helm chart values

Success criteria:
- Disruption window is weekdays 2-6 AM UTC
- `concurrency: 1` ensures sequential reboots
- Metrics and service are enabled

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 330-380) — Kured values YAML
- [kured-configuration-research.md](../../research/subagents/2026-03-04/kured-configuration-research.md) (Lines 1-80) — Kured overview and parameters

Dependencies:
- None

## Implementation Phase 3: Test and Monitoring Scripts

<!-- parallelizable: true -->

### Step 3.1: Create `scripts/availability-probe.sh` — continuous curl probe with CSV logging

Create a bash script that sends HTTP requests every 0.5s to a given service IP, logs results to CSV, and reports pass/fail with a 99.9% availability threshold.

Script arguments:
- `$1` — Service IP address
- `$2` — Duration in seconds (default: 600)

Output format: `timestamp,status_code,response_time_ms` CSV file.

Exit code: 0 if zero failures, 1 if any failure.

Use the complete script from the testing research (Option 1: curl loop).

Files:
- `scripts/availability-probe.sh` - New file, availability probe script

Success criteria:
- Script accepts SERVICE_IP and DURATION arguments
- Outputs CSV with timestamp, status_code, response_time_ms columns
- Reports total requests, failed requests, success rate
- Exits 1 if any non-200 response

Context references:
- [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) (Lines 210-270) — Complete curl probe script

Dependencies:
- None (standalone script)

### Step 3.2: Create `scripts/e2e-test.sh` — orchestrates sentinel creation, probing, and result analysis

Create the end-to-end test script that:

1. Validates prerequisites (namespace, deployment, PDB, Kured, service IP)
2. Starts continuous availability probe in background
3. Captures Kured logs in background
4. Creates `/var/run/reboot-required` sentinel on all nodes via `kubectl debug`
5. Monitors node status transitions every 30s
6. Waits for all nodes to return to Ready
7. Analyzes probe results (success rate, latency stats)
8. Collects final cluster state
9. Reports pass/fail verdict

Use the complete 150-line e2e script from the testing research.

Files:
- `scripts/e2e-test.sh` - New file, end-to-end test orchestrator

Success criteria:
- Script validates all prerequisites before starting
- Probe runs in background concurrent with reboot simulation
- Sentinel files created on all nodes via `kubectl debug`
- Node monitoring with 30s intervals
- Results directory with probe CSV, node log, Kured log, summary
- Exit 0 if zero failures, exit 1 otherwise

Context references:
- [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) (Lines 685-900) — Complete e2e test script

Dependencies:
- Step 3.1 concept (probe logic is embedded, not called externally)

### Step 3.3: Create `scripts/collect-artifacts.sh` — gathers Kured logs, KQL results, PDB snapshots

Create an artifact collection script that gathers all proof artifacts after a test run:

- Node status (`kubectl get nodes -o wide`)
- Pod status (`kubectl get pods -n demo -o wide`)
- PDB YAML export (`kubectl get pdb -n demo -o yaml`)
- Events (`kubectl get events -n demo --sort-by='.lastTimestamp'`)
- Kured logs (`kubectl logs -n kube-system -l app.kubernetes.io/name=kured --since=2h`)
- Kured DaemonSet YAML export
- Per-node descriptions

All artifacts saved to `proof-artifacts/<timestamp>/` directory.

Files:
- `scripts/collect-artifacts.sh` - New file, artifact collection script

Success criteria:
- Creates timestamped directory under `proof-artifacts/`
- Collects all 7+ artifact types listed above
- Handles missing resources gracefully

Context references:
- [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) (Lines 1020-1065) — Artifact collection script

Dependencies:
- None (standalone script)

## Implementation Phase 4: GitHub Actions Workflows

<!-- parallelizable: false -->

### Step 4.1: Create `.github/workflows/deploy.yml` — tear-up workflow

Create the full deploy workflow triggered by `workflow_dispatch`. Three chained jobs:

**Job 1: `deploy-infrastructure`**
- Inputs: `environment` (default: `poc`), `location` (default: `canadacentral`), `node_count` (default: `3`)
- Permissions: `id-token: write`, `contents: read`
- Steps: checkout → Azure login (OIDC) → create resource group → deploy Bicep via `azure/arm-deploy@v2` → verify provisioning
- Env: `RESOURCE_GROUP=rg-aks-kured-<env>`, `CLUSTER_NAME=aks-kured-<env>`
- Outputs: `cluster-name`, `resource-group`

**Job 2: `install-kured`** (needs: `deploy-infrastructure`)
- Steps: checkout → Azure login → setup Helm v3.16.0 → set AKS context → add kured Helm repo → install kured with `--values ./k8s/kured-values.yaml` → verify DaemonSet

**Job 3: `deploy-workload`** (needs: `install-kured`)
- Steps: checkout → Azure login → set AKS context → apply namespace, deployment, service, PDB → wait for rollout → verify PDB → verify LoadBalancer IP

Use the correct namespace and resource names:
- Namespace: `demo` (not `sample-app`)
- Deployment: `zero-downtime-web`
- Service: `zero-downtime-web`
- PDB: `zero-downtime-web-pdb`

Files:
- `.github/workflows/deploy.yml` - New file, deployment workflow

Discrepancy references:
- DD-01: Research workflow uses `sample-app` namespace in some places; plan standardizes on `demo` namespace throughout

Success criteria:
- Workflow runs on `workflow_dispatch` with 3 optional inputs
- OIDC authentication with 3 secrets
- Three chained jobs with proper `needs` dependencies
- Kured installed from values file
- Workload manifests applied from `k8s/workload/` directory

Context references:
- [github-actions-workflows-research.md](../../research/subagents/2026-03-04/github-actions-workflows-research.md) (Lines 340-520) — Deploy workflow YAML
- [github-actions-workflows-research.md](../../research/subagents/2026-03-04/github-actions-workflows-research.md) (Lines 35-75) — OIDC setup

Dependencies:
- Phase 1 (Bicep file paths)
- Phase 2 (manifest file paths)

### Step 4.2: Create `.github/workflows/teardown.yml` — destroy resource group

Create the teardown workflow triggered by `workflow_dispatch`:

- Inputs: `environment`, `confirm` (must type `DELETE`)
- Job 1: `validate` — check confirmation string
- Job 2: `teardown` — check RG exists → `az group delete --yes --no-wait` → wait for deletion

Files:
- `.github/workflows/teardown.yml` - New file, teardown workflow

Success criteria:
- Requires `DELETE` confirmation input
- Checks resource group exists before attempting delete
- Uses `--no-wait` + `az group wait --deleted`

Context references:
- [github-actions-workflows-research.md](../../research/subagents/2026-03-04/github-actions-workflows-research.md) (Lines 525-575) — Teardown workflow YAML

Dependencies:
- None (standalone workflow)

### Step 4.3: Create `.github/workflows/test.yml` — availability test + simulated reboot

Create the test workflow triggered by `workflow_dispatch`:

- Inputs: `environment`, `test_duration` (default: 300), `simulate_reboot` (choice: true/false)
- Job 1: `setup-test` — get service IP, record pre-test state
- Job 2: `availability-test` (parallel with simulate-reboot) — run curl probe for duration
- Job 3: `simulate-reboot` (parallel with availability-test, conditional on `simulate_reboot == 'true'`) — create sentinel file on all nodes via `kubectl debug` loop, wait for Kured
- Job 4: `post-test-validation` (needs both, `if: always()`) — final state, validate pods running, nodes ready

Use `demo` namespace and `zero-downtime-web` names throughout (not `sample-app`).

Availability threshold: 100% (zero failures) for the POC proof, matching e2e-test.sh and success criteria. The workflow step should exit 1 on any non-200 response.

Files:
- `.github/workflows/test.yml` - New file, test workflow

Discrepancy references:
- DD-01: Research uses `sample-app` namespace; corrected to `demo` for consistency

Success criteria:
- Parallel availability-test and simulate-reboot jobs
- Availability threshold: 99.9%
- Post-test validation runs always
- Sentinel file created via privileged pod

Context references:
- [github-actions-workflows-research.md](../../research/subagents/2026-03-04/github-actions-workflows-research.md) (Lines 580-900) — Test workflow YAML

Dependencies:
- Phase 3 scripts (conceptual reference; scripts used separately for local runs)

## Implementation Phase 5: Documentation

<!-- parallelizable: false -->

### Step 5.1: Create `README.md` with full documentation

Create a comprehensive README covering:

1. **Title and badges**: AKS Kured Zero-Downtime Node Reboot POC
2. **Architecture overview**: Diagram showing AKS 3-node cluster → Kured DaemonSet → unattended-upgrades → sentinel → drain → reboot → uncordon
3. **How it works**: Summary of Kured process (7 steps from research Key Discovery §1)
4. **Prerequisites**: Azure subscription, Azure CLI, Helm, kubectl, GitHub repo with OIDC secrets
5. **OIDC setup instructions**: App registration + federated credential + secrets
6. **Repository structure**: Tree diagram from research §7
7. **Quick start**: 
   - Option A: GitHub Actions (`deploy.yml` → `test.yml` → `teardown.yml`)
   - Option B: Manual CLI deployment steps
8. **Demo runbook**: 8-step runbook from research §Demo Runbook
9. **Kured configuration**: Explain disruption window, lock behavior, how to override for demo
10. **Testing**: How to run e2e test, what the probe validates, interpreting results
11. **Monitoring**: KQL queries for Container Insights, kubectl log commands
12. **Cleanup**: `teardown.yml` or manual `az group delete`

Files:
- `README.md` - New file, project documentation

Success criteria:
- All sections listed above are covered
- Architecture overview is clear
- Quick start provides actionable commands
- Demo runbook matches actual workflow names and resource names

Context references:
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 625-659) — Demo Runbook
- [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) (Lines 567-590) — Repository structure

Dependencies:
- All prior phases (for accurate file references)

### Step 5.2: Update `.gitignore` for build artifacts and test output

Add entries for:
- `test-results/` — e2e test output
- `proof-artifacts/` — collected proof artifacts
- `*.log` — log files
- Bicep build artifacts (`.json` generated from build, but keep `parameters.json`)

Files:
- `.gitignore` - Modify existing file

Success criteria:
- Test output directories excluded
- Build artifacts excluded
- `parameters.json` NOT excluded

Dependencies:
- None

## Implementation Phase 6: Validation

<!-- parallelizable: false -->

### Step 6.1: Run full project validation

Execute all validation commands for the project:
- `az bicep build --file infra/main.bicep` — Bicep compilation
- `kubectl apply --dry-run=client -f k8s/workload/` — YAML manifest syntax (requires kubectl but not a cluster)
- Verify GitHub Actions YAML is valid (parse with a YAML linter or `python -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))"`)
- `bash -n scripts/availability-probe.sh` — bash syntax check
- `bash -n scripts/e2e-test.sh` — bash syntax check
- `bash -n scripts/collect-artifacts.sh` — bash syntax check

### Step 6.2: Fix minor validation issues

Iterate on lint errors, build warnings, and test failures. Apply fixes directly when corrections are straightforward and isolated.

### Step 6.3: Report blocking issues

When validation failures require changes beyond minor fixes:
- Document the issues and affected files.
- Provide the user with next steps.
- Recommend additional research and planning rather than inline fixes.
- Avoid large-scale refactoring within this phase.

## Dependencies

- **Azure CLI** (2.60+) with Bicep CLI
- **Helm 3** (3.16.0 pinned in workflow)
- **kubectl** (compatible with target K8s version)
- **bash** (for test scripts)
- **GitHub Actions** (ubuntu-latest runners)
- **Azure subscription** (Contributor role)

## Success Criteria

- Bicep compiles without errors
- All Kubernetes manifests pass dry-run validation
- All bash scripts pass syntax check
- GitHub Actions workflows are valid YAML
- README documents all steps from deploy to teardown
- Consistent naming: `demo` namespace, `zero-downtime-web` deployment/service, `aks-kured-poc` cluster

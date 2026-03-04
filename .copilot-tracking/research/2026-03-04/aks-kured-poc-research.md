<!-- markdownlint-disable-file -->
# Task Research: AKS Kured Zero-Downtime Node Reboot POC

Deploy an AKS cluster with 3 Linux (Ubuntu) nodes to demonstrate leveraging Kured (KUbernetes REboot Daemon) for zero-downtime node image updates, with controlled disruption windows, Bicep IaC, GitHub Actions workflows for tear-up/tear-down, and tests/monitoring to prove the approach. Starting point: <https://learn.microsoft.com/en-us/azure/aks/upgrade-node-image-kured>

## Task Implementation Requests

* Deploy AKS cluster with 3 Linux nodes using Bicep
* Install and configure Kured for controlled reboot scheduling with a defined disruption window
* Implement PodDisruptionBudgets and pod anti-affinity for zero-downtime
* Create GitHub Actions workflows for cluster provisioning (tear-up) and teardown
* Deploy a sample workload to prove zero-downtime during reboots
* Implement tests and monitoring to validate zero-downtime behavior
* Document the demo flow end-to-end

## Scope and Success Criteria

* Scope: Complete POC including IaC (Bicep), Kured configuration, sample workload, GitHub Actions CI/CD, availability tests, and monitoring — all in a single repository
* Assumptions:
  * Azure subscription available with sufficient permissions
  * GitHub Actions runners have Azure credentials (OIDC federated credentials)
  * AKS uses Ubuntu node OS (default) since Kured relies on `/var/run/reboot-required` sentinel
  * Kured installed via Helm
  * No custom VNet required (kubenet default sufficient)
  * Public images used for sample workload (no ACR needed)
* Success Criteria:
  * AKS cluster with 3 Linux nodes deploys successfully via Bicep
  * Kured is installed and configured with a defined reboot window (specific days/hours)
  * Sample 3-replica nginx workload survives node reboots with zero downtime (100% HTTP 200)
  * PodDisruptionBudgets prevent all replicas from being evicted simultaneously
  * GitHub Actions workflows can create and destroy the entire environment via `workflow_dispatch`
  * Automated test validates availability during simulated reboot scenarios
  * Container Insights KQL queries and Kured logs prove zero request loss and sequential reboot behavior

## Outline

1. [AKS Bicep deployment](#1-aks-bicep-deployment)
2. [Kured installation and configuration](#2-kured-installation-and-configuration)
3. [Sample workload with PodDisruptionBudgets](#3-sample-workload-with-poddisruptionbudgets)
4. [GitHub Actions workflows](#4-github-actions-workflows)
5. [Testing strategy](#5-testing-strategy)
6. [Monitoring and observability](#6-monitoring-and-observability)
7. [Repository structure](#7-repository-structure)
8. [Technical scenarios and alternatives](#8-technical-scenarios-and-alternatives)

---

## Research Executed

### File Analysis

* Subagent: [kured-configuration-research.md](../subagents/2026-03-04/kured-configuration-research.md) — 513 lines covering Kured overview, Helm installation, reboot window configuration, PDB interaction, Prometheus metrics, notification hooks, complete Helm values reference
* Subagent: [aks-bicep-deployment-research.md](../subagents/2026-03-04/aks-bicep-deployment-research.md) — 615 lines covering AKS resource definition, node pool configuration, auto-upgrade channels, Container Insights, complete Bicep template with parameters
* Subagent: [github-actions-workflows-research.md](../subagents/2026-03-04/github-actions-workflows-research.md) — 1061 lines covering OIDC authentication, Bicep deployment, Helm installation, complete deploy/teardown/test workflow YAML
* Subagent: [testing-monitoring-research.md](../subagents/2026-03-04/testing-monitoring-research.md) — 1121 lines covering sample workload design, PDB configuration, three availability probe approaches, KQL queries, Prometheus metrics, e2e test script, proof artifacts

### External Research

* Microsoft Docs: [Apply security and kernel updates to Linux nodes in AKS](https://learn.microsoft.com/en-us/azure/aks/node-updates-kured)
  * Describes unattended-upgrades + Kured approach for in-place node patching
* Kured GitHub: <https://github.com/kubereboot/kured>
  * Current version: 1.21.0 (app), Helm chart 5.11.0
  * CNCF Sandbox project, Apache-2.0 license
* Kured Helm chart: <https://kubereboot.github.io/charts/>
  * Chart name: `kured`, repo: `kubereboot`
* Shoutrrr notifications: <https://containrrr.dev/shoutrrr/v0.7/services/overview>
  * Supports Slack, Teams, Rocket.Chat, SMTP via `--notify-url`

### Project Conventions

* Repository: `devopsabcs-engineering/aks-kured-poc` — fresh repo with only `.gitignore`
* Standards: Bicep for IaC, GitHub Actions for CI/CD, Kubernetes manifests for workloads

---

## Key Discoveries

### 1. How Kured Works

Kured (KUbernetes REboot Daemon) is a CNCF Sandbox project that deploys as a DaemonSet on every Linux node. It polls for the sentinel file `/var/run/reboot-required` (created by Ubuntu's `unattended-upgrades` after kernel/security patches) and orchestrates safe, sequential reboots:

1. Detect sentinel file on a node
2. Acquire cluster-wide lock (DaemonSet annotation `weave.works/kured-node-lock`) — only one node at a time
3. Cordon the node (prevent new pod scheduling)
4. Drain the node (evict pods respecting PodDisruptionBudgets)
5. Reboot via `systemctl reboot`
6. After node returns, uncordon it
7. Release lock, allowing next node to proceed

Source: [kured-configuration-research.md](../subagents/2026-03-04/kured-configuration-research.md)

### 2. Critical AKS Setting: nodeOSUpgradeChannel = Unmanaged

For Kured to work, the AKS cluster must set `autoUpgradeProfile.nodeOSUpgradeChannel` to `Unmanaged`. This allows Ubuntu's built-in `unattended-upgrades` to install security patches in-place and create the reboot sentinel file. Other channels (`SecurityPatch`, `NodeImage`) conflict with or replace Kured's role.

| Channel         | Behavior                                          | Kured Compatible? |
|-----------------|---------------------------------------------------|-------------------|
| `None`          | No automatic OS updates                           | Yes (manual only) |
| **`Unmanaged`** | **OS handles updates + creates reboot sentinel**  | **Best fit**      |
| `SecurityPatch` | AKS applies security patches, may auto-reboot     | Conflicts         |
| `NodeImage`     | AKS reimages entire node                          | Replaces Kured    |

Source: [aks-bicep-deployment-research.md](../subagents/2026-03-04/aks-bicep-deployment-research.md)

### 3. Disruption Window Control

Kured supports schedule-based reboot windows via Helm values:

```yaml
configuration:
  rebootDays: [mo, tu, we, th, fr]
  startTime: "2am"
  endTime: "6am"
  timeZone: "America/New_York"
  period: "15m"  # Check frequency (reduce for narrow windows)
```

Combined with the cluster-wide lock (only one node reboots at a time) and `lockReleaseDelay` (throttle between reboots), this provides full control over the disruption window.

Source: [kured-configuration-research.md](../subagents/2026-03-04/kured-configuration-research.md)

### 4. PDB + Anti-Affinity = Zero Downtime

With 3 replicas on 3 nodes:

* **PodDisruptionBudget** (`minAvailable: 2`) ensures at least 2 replicas always run during drains
* **Pod anti-affinity** (`preferredDuringSchedulingIgnoredDuringExecution` on `kubernetes.io/hostname`) spreads pods across nodes
* **preStop lifecycle hook** (`sleep 5`) gives the Service time to remove the pod from endpoints before termination

When Kured drains one node, the PDB allows evicting only that node's pod. The remaining 2 replicas continue serving traffic. The evicted pod reschedules to one of the 2 remaining nodes.

Source: [testing-monitoring-research.md](../subagents/2026-03-04/testing-monitoring-research.md)

### 5. OIDC Authentication for GitHub Actions

OIDC federation (federated credentials) is the recommended authentication for GitHub Actions → Azure. No long-lived secrets to rotate. Requires:

* Azure AD app registration with federated credential for the GitHub repo
* Three secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
* Workflow permission: `id-token: write`

Source: [github-actions-workflows-research.md](../subagents/2026-03-04/github-actions-workflows-research.md)

### 6. Testing: Simulated Reboot via Sentinel File

For the POC, reboots are triggered by creating `/var/run/reboot-required` on nodes via `kubectl debug`:

```bash
for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  kubectl debug node/"${NODE}" -it --image=busybox:1.36 -- \
    sh -c "chroot /host touch /var/run/reboot-required"
done
```

A continuous curl probe (HTTP requests every 0.5s) against the LoadBalancer IP validates zero failures during the entire reboot cycle.

Source: [testing-monitoring-research.md](../subagents/2026-03-04/testing-monitoring-research.md)

### 7. Container Insights KQL Queries for Proof

Six KQL queries prove zero-downtime:

1. **Node Ready/NotReady transitions**: `KubeNodeInventory` showing sequential NotReady→Ready per node
2. **Pod restart counts**: `KubePodInventory` confirming minimal/zero restarts
3. **Pod eviction timeline**: `KubeEvents` showing eviction and rescheduling
4. **Kured activity logs**: `ContainerLogV2` for drain/reboot/uncordon messages
5. **Node drain timeline**: `KubeEvents` for cordon/drain operations
6. **Service endpoint changes**: `KubeEvents` for endpoint updates

Source: [testing-monitoring-research.md](../subagents/2026-03-04/testing-monitoring-research.md)

---

## Complete Implementation Details

### 1. AKS Bicep Deployment

#### main.bicep

```bicep
// main.bicep — AKS cluster for Kured zero-downtime POC

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the AKS cluster.')
@minLength(3)
@maxLength(63)
param clusterName string

@description('DNS prefix for the AKS cluster FQDN.')
param dnsPrefix string = clusterName

@description('Kubernetes version. Leave empty for default latest stable.')
param kubernetesVersion string = ''

@description('Number of nodes in the system node pool.')
@minValue(1)
@maxValue(10)
param nodeCount int = 3

@description('VM size for the system node pool.')
param vmSize string = 'Standard_DS2_v2'

@description('OS disk size in GB.')
param osDiskSizeGB int = 30

@description('Name of the Log Analytics workspace for Container Insights.')
param logAnalyticsWorkspaceName string = '${clusterName}-logs'

@description('Log Analytics workspace retention in days.')
@minValue(30)
@maxValue(365)
param logRetentionDays int = 30

@description('Tags to apply to all resources.')
param tags object = {
  project: 'aks-kured-poc'
  environment: 'poc'
}

// Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
  }
}

// AKS Managed Cluster
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: clusterName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: kubernetesVersion != '' ? kubernetesVersion : null
    agentPoolProfiles: [
      {
        name: 'systempool'
        count: nodeCount
        vmSize: vmSize
        osType: 'Linux'
        osSKU: 'Ubuntu'
        mode: 'System'
        osDiskSizeGB: osDiskSizeGB
        osDiskType: 'Ephemeral'
        type: 'VirtualMachineScaleSets'
        maxPods: 110
      }
    ]
    networkProfile: {
      networkPlugin: 'kubenet'
      loadBalancerSku: 'standard'
    }
    addonProfiles: {
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspace.id
        }
      }
    }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'Unmanaged'  // Critical: lets unattended-upgrades + Kured handle reboots
    }
  }
}

// Outputs
output controlPlaneFqdn string = aksCluster.properties.fqdn
output clusterName string = aksCluster.name
output clusterResourceId string = aksCluster.id
output nodeResourceGroup string = aksCluster.properties.nodeResourceGroup
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
```

#### parameters.json

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

**Key design decisions:**

* `Standard_DS2_v2` (2 vCPU, 7 GiB RAM) — supports ephemeral OS disks (86 GiB cache), consistent non-burstable performance, ~$100/mo per node
* `nodeOSUpgradeChannel: 'Unmanaged'` — the critical setting enabling Kured workflow
* `upgradeChannel: 'patch'` — Kubernetes patches auto-applied, but node OS reboots controlled by Kured
* `osDiskType: 'Ephemeral'` — faster reimaging, lower cost, acceptable for stateless AKS nodes
* Kubenet networking — simplest for POC, no VNet planning needed
* Container Insights via `omsagent` addon — essential for proof via KQL queries

### 2. Kured Installation and Configuration

#### kured-values.yaml

```yaml
# k8s/kured-values.yaml — Kured Helm chart configuration

configuration:
  # Disruption window: weekdays 2-6 AM UTC
  rebootDays:
    - mo
    - tu
    - we
    - th
    - fr
  startTime: "2am"
  endTime: "6am"
  timeZone: "UTC"

  # Check for sentinel every 1 minute (frequent for POC demo)
  period: "1m"

  # Drain configuration
  drainGracePeriod: "60"
  drainTimeout: "300s"

  # Lock safety
  lockTtl: "30m"
  lockReleaseDelay: "5m"

  # Annotate nodes with reboot status
  annotateNodes: true

  # Only one node at a time
  concurrency: 1

  # Logging
  logFormat: "text"

# Metrics for monitoring
metrics:
  create: true
  labels: {}
  interval: 60s

service:
  create: true
  port: 8080

# Linux nodes only
nodeSelector:
  kubernetes.io/os: linux

# Resource limits
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 50m
    memory: 64Mi
```

**Installation command:**

```bash
helm repo add kubereboot https://kubereboot.github.io/charts/
helm repo update
helm upgrade --install kured kubereboot/kured \
  --namespace kube-system \
  --values ./k8s/kured-values.yaml \
  --wait --timeout 5m
```

**For POC testing (wider window):** Override `startTime`/`endTime` to allow reboots anytime during demo.

### 3. Sample Workload with PodDisruptionBudgets

#### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: demo
```

#### deployment.yaml

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

#### service.yaml

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

#### pdb.yaml

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

### 4. GitHub Actions Workflows

Three workflows: `deploy.yml` (tear-up), `teardown.yml`, `test.yml` — all `workflow_dispatch`.

Complete YAML with job chains, OIDC auth, Helm install, and test orchestration available in [github-actions-workflows-research.md](../subagents/2026-03-04/github-actions-workflows-research.md).

**Workflow architecture:**

```text
deploy.yml:
  deploy-infrastructure → install-kured → deploy-workload

test.yml:
  setup-test → [availability-test ∥ simulate-reboot] → post-test-validation

teardown.yml:
  validate → teardown (with DELETE confirmation)
```

### 5. Testing Strategy

**Availability probe:** Curl loop sending HTTP requests every 0.5s to LoadBalancer IP, logging to CSV, 99.9% threshold.

**Reboot trigger:** Create sentinel files on all nodes via `kubectl debug`.

**E2E test script:** Orchestrates probe + sentinel creation + node monitoring + result analysis. Complete script in [testing-monitoring-research.md](../subagents/2026-03-04/testing-monitoring-research.md).

### 6. Monitoring and Observability

**Container Insights KQL queries** for node transitions, pod events, Kured logs.

**Kured Prometheus metrics:** `kured_reboot_required`, `kured_drain_blocked_by_pdb`, `kured_reboot_count`.

**Proof artifacts:** Probe CSV, test summary, node timeline log, Kured logs, KQL results, PDB snapshots.

### 7. Repository Structure

```text
aks-kured-poc/
├── .github/
│   └── workflows/
│       ├── deploy.yml
│       ├── teardown.yml
│       └── test.yml
├── infra/
│   ├── main.bicep
│   └── parameters.json
├── k8s/
│   ├── kured-values.yaml
│   └── workload/
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       └── pdb.yaml
├── scripts/
│   ├── e2e-test.sh
│   ├── availability-probe.sh
│   └── collect-artifacts.sh
├── .gitignore
└── README.md
```

---

## 8. Technical Scenarios and Alternatives

### Scenario A: Kured + Unattended Upgrades (Selected)

**Description:** Ubuntu's `unattended-upgrades` installs daily security patches. Kured detects `/var/run/reboot-required` and orchestrates sequential reboots respecting PDBs.

**Advantages:** Continuous patching, controlled disruption window, one node at a time, PDB-backed zero-downtime, Microsoft-recommended approach.

**Limitations:** New scaled-out nodes use original image, depends on `unattended-upgrades`, sequential reboots take 15-60 min for 3 nodes.

**Why selected:** Exact approach from [Microsoft AKS + Kured docs](https://learn.microsoft.com/en-us/azure/aks/node-updates-kured). Meets all requirements: Kured demonstration, disruption window control, zero-downtime proof.

### Scenario B: AKS Node Image Auto-Upgrade (Rejected)

`nodeOSUpgradeChannel: NodeImage` — AKS replaces VMs weekly. No Kured dependency, but no disruption window control and doesn't demonstrate Kured.

### Scenario C: AKS SecurityPatch Channel (Rejected)

`nodeOSUpgradeChannel: SecurityPatch` — AKS applies patches, may auto-reboot. Conflicts with Kured's reboot management.

### Scenario D: Manual az CLI Upgrade (Complement)

`az aks nodepool upgrade --node-image-only` — periodic base image refresh. Can complement Scenario A but not a substitute for daily patching.

---

## Potential Next Research

* **Azure Linux 3 vs Ubuntu**: Azure Linux 2.0 retiring March 31, 2026. Sentinel file mechanism may differ. Stick with Ubuntu `osSKU: 'Ubuntu'` for now.
* **Kured notifications**: Slack/Teams via Shoutrrr `notifyUrl`.
* **Prometheus/Grafana**: Optional kube-prometheus-stack deployment for richer dashboards.
* **Azure Monitor Workbook**: Pre-built workbook template for demo visualization.
* **Multi-node-pool**: Test Kured across system + user pools.

---

## Configuration Examples

### OIDC Setup (Prerequisites)

```bash
az ad app create --display-name "aks-kured-poc-gh-actions"
az ad app federated-credential create --id <APP_ID> --parameters '{
  "name": "github-aks-kured-poc",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:devopsabcs-engineering/aks-kured-poc:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
az ad sp create --id <APP_ID>
az role assignment create --assignee <APP_ID> --role Contributor --scope /subscriptions/<SUB_ID>
```

### GitHub Repository Secrets

| Secret                   | Value                      |
|--------------------------|----------------------------|
| `AZURE_CLIENT_ID`        | App registration client ID |
| `AZURE_TENANT_ID`        | Azure AD tenant ID         |
| `AZURE_SUBSCRIPTION_ID`  | Target subscription ID     |

### Manual Kured Lock Control

```bash
# Disable reboots
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock='{"nodeID":"manual"}'
# Re-enable
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock-
```

---

## Demo Runbook

1. **Deploy**: Trigger `deploy.yml` → creates RG, AKS (3 nodes), installs Kured, deploys 3-replica nginx
2. **Verify**: 3 nodes Ready, 3 pods on separate nodes, PDB active, Kured DaemonSet running
3. **Override window** (if needed): `helm upgrade` with wide reboot window for demo
4. **Run test**: Trigger `test.yml` → availability probe + sentinel file creation
5. **Monitor**: Kured logs, node status, pod distribution
6. **Observe**: Nodes reboot sequentially, pods reschedule, service stays up
7. **Validate**: 100% availability in probe, KQL confirms sequential reboots
8. **Teardown**: Trigger `teardown.yml` → deletes resource group

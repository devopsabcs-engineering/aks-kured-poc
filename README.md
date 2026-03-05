---
title: AKS Kured Zero-Downtime Node Reboot POC
description: Proof-of-concept demonstrating zero-downtime node reboots on AKS using Kured and PodDisruptionBudgets
author: devopsabcs-engineering
ms.date: 2026-03-04
---

## Overview

This proof-of-concept demonstrates zero-downtime node reboots on Azure Kubernetes Service (AKS) using [Kured](https://kured.dev/) (KUbernetes REboot Daemon) combined with PodDisruptionBudgets. When Ubuntu nodes install unattended security updates that require a reboot, Kured detects the pending reboot, drains each node one at a time while respecting PDB constraints, reboots the node, then moves on to the next -- all without dropping a single request to the running workload.

## Architecture

```text
+---------------------+       +----------------+       +-----------------+
| Ubuntu Node         |       | Kured DaemonSet|       | Kubernetes API  |
| (unattended-upgrade)|       | (per node)     |       |                 |
+---------------------+       +----------------+       +-----------------+
         |                            |                         |
   1. Installs security               |                         |
      updates, writes                  |                         |
      /var/run/reboot-required         |                         |
         |                            |                         |
         +---> 2. Kured polls --------+                         |
               sentinel file                                    |
                      |                                         |
                3. Acquires cluster-wide lock (one node at a time)
                      |                                         |
                4. Cordons + drains node (respects PDB) ------->|
                      |                                         |
                5. Reboots node                                 |
                      |                                         |
                6. Node rejoins, uncordoned ------------------->|
                      |                                         |
                7. Releases lock, next node proceeds            |
```

## How It Works

1. **Sentinel detection** -- Ubuntu `unattended-upgrades` installs security patches and writes `/var/run/reboot-required` when a reboot is needed.
2. **Poll loop** -- Kured runs as a DaemonSet on every node and checks for the sentinel file on a configurable interval (1 minute in this POC).
3. **Distributed lock** -- Before acting, the Kured pod acquires a cluster-wide lock so that only one node reboots at a time.
4. **Cordon and drain** -- Kured cordons the node and drains all workload pods. The drain respects PodDisruptionBudgets, ensuring the minimum number of pods remains available.
5. **Reboot** -- Once the node is drained, Kured triggers the reboot.
6. **Rejoin** -- After the node boots back up, Kubernetes marks it Ready. Kured uncordons the node so new pods can be scheduled on it.
7. **Release and repeat** -- Kured releases the cluster-wide lock, and the next pending node begins the same cycle.

## Repository Structure

```text
aks-kured-poc/
├── .github/
│   └── workflows/
│       ├── deploy.yml          # Provisions AKS, installs Kured, deploys workload (idempotent)
│       ├── test.yml            # Runs availability test and simulates reboots (wide window by default)
│       └── teardown.yml        # Deletes the resource group and disables test schedule
├── infra/
│   ├── main.bicep              # AKS cluster + Log Analytics + Data Collection Rule (Bicep)
│   └── parameters.json         # Default parameter values
├── k8s/
│   ├── kured-values.yaml       # Kured Helm values
│   └── workload/
│       ├── namespace.yaml      # demo namespace
│       ├── deployment.yaml     # zero-downtime-web (3 replicas, anti-affinity)
│       ├── service.yaml        # LoadBalancer service
│       └── pdb.yaml            # PodDisruptionBudget (minAvailable: 2)
├── scripts/
│   ├── availability-probe.sh   # Continuous HTTP probe with CSV output
│   ├── e2e-test.sh             # Full end-to-end reboot validation
│   └── collect-artifacts.sh    # Gathers proof artifacts from the cluster
├── test-results/
│   └── availability-history.csv # Cumulative test results (auto-updated by CI)
├── .gitignore
├── README.md
└── README.fr.md            # French translation
```

## Prerequisites

- **Azure subscription** with permissions to create resource groups, AKS clusters, and role assignments
- **Azure CLI** 2.60 or later
- **Helm** 3.x
- **kubectl** matching your cluster version
- **GitHub repository** with OIDC federated credentials configured (see below)
- **bash**, **curl**, **jq**, and **bc** (for running scripts locally)

## OIDC Setup for GitHub Actions

The GitHub Actions workflows authenticate to Azure using OpenID Connect (OIDC) with a federated credential. No client secrets are stored.

### 1. Create an app registration and service principal

```bash
az ad app create --display-name "aks-kured-poc-github"
```

Note the `appId` from the output.

### 2. Create a service principal and assign the Contributor role

```bash
APP_ID="<appId from previous step>"

az ad sp create --id "$APP_ID"

az role assignment create \
  --assignee "$APP_ID" \
  --role Contributor \
  --scope "/subscriptions/<SUBSCRIPTION_ID>"
```

### 3. Add a federated credential for your GitHub repository

```bash
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name": "aks-kured-poc-main",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<OWNER>/aks-kured-poc:ref:refs/heads/main",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

Replace `<OWNER>` with your GitHub organization or username. If workflows run on pull requests or other branches, add additional federated credentials with the appropriate subject.

### 4. Configure GitHub repository secrets

Add the following secrets to your repository under **Settings > Secrets and variables > Actions**:

| Secret Name              | Value                                             |
| ------------------------ | ------------------------------------------------- |
| `AZURE_CLIENT_ID`        | Application (client) ID from the app registration |
| `AZURE_TENANT_ID`        | Azure AD tenant ID                                |
| `AZURE_SUBSCRIPTION_ID`  | Target Azure subscription ID                      |

## Quick Start

### Option A: GitHub Actions (recommended)

1. Push this repository to GitHub with the OIDC secrets configured.
2. Go to **Actions** and trigger the **Deploy AKS Kured POC** (`deploy.yml`) workflow. Accept the defaults or override location, node count, VM size, etc. When the workflow finishes, the **job summary** displays a clickable public URL for the deployed service.
3. Once deployment completes, trigger the **Test AKS Kured POC** (`test.yml`) workflow. Set `simulate_reboot` to `true` to create sentinel files on all nodes. By default the test workflow uses a **24/7 reboot window** (all days, 0 AM -- 11:59 PM) so reboots trigger immediately without waiting for the narrow production window. The workflow also runs on a **30-minute cron schedule** to continuously populate availability history.
4. After validation, trigger the **Teardown AKS Kured POC** (`teardown.yml`) workflow. Type `DELETE` when prompted to confirm. The teardown also **disables the test workflow schedule** to prevent failed cron runs against a deleted cluster.

> **Tip:** Both `deploy.yml` and `test.yml` are fully idempotent and safe to re-run at any time.

### Option B: Manual CLI

```bash
# Variables
RESOURCE_GROUP="rg-aks-kured-poc"
CLUSTER_NAME="aks-kured-poc"
LOCATION="canadacentral"

# 1. Create resource group
az group create --name "$RESOURCE_GROUP" --location "$LOCATION"

# 2. Deploy infrastructure
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters infra/parameters.json

# 3. Get cluster credentials
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME"

# 4. Install Kured via Helm
helm repo add kured https://kubereboot.github.io/charts
helm repo update
helm upgrade --install kured kured/kured \
  --namespace kube-system \
  --values k8s/kured-values.yaml \
  --wait

# 5. Deploy sample workload
kubectl apply -f k8s/workload/namespace.yaml
kubectl apply -f k8s/workload/deployment.yaml
kubectl apply -f k8s/workload/service.yaml
kubectl apply -f k8s/workload/pdb.yaml

# 6. Wait for rollout
kubectl rollout status deployment/zero-downtime-web --namespace demo --timeout=300s
```

## Kured Configuration

The Kured Helm values in `k8s/kured-values.yaml` define the following behavior:

| Setting           | Value             | Purpose                                                    |
| ----------------- | ----------------- | ---------------------------------------------------------- |
| `rebootDays`      | mo-fr             | Reboots only on weekdays                                   |
| `startTime`       | 2:00 AM UTC       | Disruption window start                                    |
| `endTime`         | 6:00 AM UTC       | Disruption window end                                      |
| `period`          | 1m                | How often each node checks for the sentinel (short for POC)|
| `drainGracePeriod`| 60s               | Grace period for pod termination during drain              |
| `drainTimeout`    | 300s              | Maximum time to wait for drain to complete                 |
| `lockTtl`         | 30m               | Time-to-live for the distributed reboot lock               |
| `lockReleaseDelay`| 1m                | Delay after reboot before releasing the lock (short for POC) |
| `concurrency`     | 1                 | Only one node reboots at a time                            |

### VM size and reliability

The default VM size is `Standard_D4s_v3` (4 vCPU / 16 GB RAM). Using a larger VM
reduces the likelihood of transient probe failures during reboots. On smaller
sizes such as `Standard_DS2_v2` (2 vCPU / 7 GB RAM), the Azure Load Balancer
occasionally routes a request to a draining node during the 1--2 seconds before
the backend pool is updated, resulting in a single failed probe per reboot cycle.

To change the VM size, override the `vm_size` input when triggering `deploy.yml`
or update the `vmSize` parameter in `infra/main.bicep`.

### Overriding the disruption window for demos

By default, Kured only reboots within the 2--6 AM UTC weekday window. To override this for an immediate demo, widen the window:

```bash
helm upgrade kured kured/kured \
  --namespace kube-system \
  --values k8s/kured-values.yaml \
  --set configuration.startTime="0am" \
  --set configuration.endTime="11:59pm" \
  --set 'configuration.rebootDays={mo,tu,we,th,fr,sa,su}'
```

> **Note:** The `test.yml` workflow already applies this wide window automatically.
> The default input values are `0am`--`11:59pm` on all seven days so that the demo
> reboot triggers immediately. Override the inputs to restore the narrow window if needed.

The test workflow exposes these as input parameters:

| Input | Default | Description |
| --- | --- | --- |
| `kured_start_time` | `0am` | Reboot window start time |
| `kured_end_time` | `11:59pm` | Reboot window end time |
| `kured_reboot_days` | `mo,tu,we,th,fr,sa,su` | Comma-separated list of allowed reboot days |

## Demo Runbook

Follow these steps to run a complete zero-downtime reboot demonstration.

### Step 1: Deploy

Trigger the `deploy.yml` workflow from GitHub Actions (or follow the manual CLI steps above). This provisions the AKS cluster, installs Kured, and deploys the sample workload.

### Step 2: Verify

Confirm the cluster is in the expected state:

```bash
# All 3 nodes should be Ready
kubectl get nodes -o wide

# 3 pods running on separate nodes (anti-affinity)
kubectl get pods -n demo -o wide

# PDB is active with minAvailable: 2
kubectl get pdb -n demo

# Kured DaemonSet running on every node
kubectl get daemonset kured -n kube-system
```

### Step 3: Override disruption window (if needed)

If you are running the **manual CLI** flow and the current time is outside the 2--6 AM UTC weekday window, widen the Kured schedule:

```bash
helm upgrade kured kured/kured \
  --namespace kube-system \
  --values k8s/kured-values.yaml \
  --set configuration.startTime="0am" \
  --set configuration.endTime="11:59pm" \
  --set 'configuration.rebootDays={mo,tu,we,th,fr,sa,su}'
```

> **Note:** When using the `test.yml` GitHub Actions workflow, this step is handled
> automatically. The workflow defaults to a 24/7 window (`0am`--`11:59pm`, all days)
> and reconfigures Kured via `helm upgrade` before creating sentinel files.

### Step 4: Run the test

Trigger the `test.yml` workflow with `simulate_reboot` set to `true`. This widens the Kured reboot window (using the input parameters), creates `/var/run/reboot-required` sentinel files on every node, and runs a continuous availability probe.

Alternatively, run the local end-to-end test:

```bash
chmod +x scripts/e2e-test.sh
./scripts/e2e-test.sh
```

### Step 5: Monitor

Watch Kured activity and node status in real time:

```bash
# Kured logs (look for "Reboot required" and "Commanding reboot")
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --follow --prefix

# Node status (watch for SchedulingDisabled, NotReady, then Ready)
watch kubectl get nodes -o wide

# Pod distribution (pods reschedule to other nodes during drain)
watch kubectl get pods -n demo -o wide
```

### Step 6: Observe

During the test you should see the following sequence for each node:

1. Kured detects the sentinel and acquires the lock.
2. The node is cordoned (`SchedulingDisabled`).
3. Pods are drained (PDB ensures at least 2 remain available).
4. The node goes `NotReady` during reboot.
5. The node returns to `Ready` and is uncordoned.
6. Kured releases the lock and the next node begins.

Throughout this cycle, the service endpoint remains reachable with zero failed requests.

### Step 7: Validate

After all nodes have rebooted and returned to Ready:

```bash
# Check the probe results (should show 100% success rate)
cat test-results/*/test-summary.txt

# Collect proof artifacts
chmod +x scripts/collect-artifacts.sh
./scripts/collect-artifacts.sh
```

See the [Monitoring](#monitoring) section for KQL queries to validate in Azure Portal.

### Step 8: Teardown

Trigger the `teardown.yml` workflow and type `DELETE` to confirm. This deletes the entire resource group and **disables the test workflow schedule**.

## Testing

### Scheduled runs

The `test.yml` workflow runs automatically **every 30 minutes** via a cron schedule. Each run:

1. Creates reboot sentinel files on all nodes (triggering Kured)
2. Runs a 20-minute availability probe **while reboots are in progress**
3. Collects per-node reboot counts and appends results to [test-results/availability-history.csv](test-results/availability-history.csv)

The CSV is rendered as a sortable table in the GitHub UI, and a history summary appears on the workflow run's **job summary** page.

Scheduled runs use the default input values:

| Parameter | Default |
| --- | --- |
| `environment` | `poc` |
| `test_duration` | `1200` (20 minutes) |
| `simulate_reboot` | `true` |
| `kured_start_time` | `0am` |
| `kured_end_time` | `11:59pm` |
| `kured_reboot_days` | `mo,tu,we,th,fr,sa,su` |

> **Why 20 minutes?** Kured reboots nodes one at a time. With a 1-minute poll
> interval and a 1-minute lock release delay, each node takes roughly 5--7 minutes
> to cordon, drain, reboot, and rejoin. Three nodes require about 15--20 minutes
> total. The availability probe must run long enough to capture all transitions.

To pause scheduled runs, disable the workflow from **Actions > Test AKS Kured POC > ··· > Disable workflow**. Re-enable it when ready.

> **Important:** The schedule assumes the AKS cluster is already deployed. If the cluster has been torn down, disable the schedule to avoid failed runs.

> **Known issue -- Azure policy auto-shutdown:** Some Azure subscriptions enforce
> policies that stop or deallocate AKS clusters at midnight. When the cluster is
> stopped, kubectl cannot reach the API server and scheduled test runs will fail
> with `dial tcp: lookup ... no such host`. If your subscription has such a policy,
> either disable the cron schedule outside business hours or re-run `deploy.yml`
> each morning to start the cluster before tests resume.

### End-to-end test

The `scripts/e2e-test.sh` script runs a full validation cycle: verifies prerequisites, starts a continuous availability probe, creates reboot sentinel files on all nodes, monitors node transitions, and reports pass/fail with detailed metrics.

```bash
chmod +x scripts/e2e-test.sh
./scripts/e2e-test.sh
```

Results are written to `test-results/<timestamp>/`.

### Standalone availability probe

The `scripts/availability-probe.sh` script runs a lightweight HTTP probe against the service for a specified duration.

```bash
SERVICE_IP=$(kubectl get svc zero-downtime-web -n demo -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
chmod +x scripts/availability-probe.sh
./scripts/availability-probe.sh "$SERVICE_IP" 600
```

### Artifact collection

The `scripts/collect-artifacts.sh` script gathers node status, pod status, PDB configuration, events, Kured logs, and node descriptions into `proof-artifacts/<timestamp>/`.

```bash
chmod +x scripts/collect-artifacts.sh
./scripts/collect-artifacts.sh
```

## Monitoring

### kubectl commands

```bash
# Kured logs -- look for sentinel detection, lock acquisition, drain, and reboot
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --tail=200

# Node conditions over time
kubectl get nodes -o wide

# PDB status during drains
kubectl get pdb -n demo -o wide

# Events in the demo namespace
kubectl get events -n demo --sort-by='.lastTimestamp'
```

### KQL queries for Container Insights

These queries can be run in Azure Portal under **Log Analytics workspace > Logs** or under the AKS cluster's **Monitoring > Logs** blade.

**Node status transitions (Ready/NotReady/Unknown):**

```kql
KubeNodeInventory
| where TimeGenerated > ago(4h)
| project TimeGenerated, Computer, Status
| order by TimeGenerated asc
```

**Pod lifecycle events during reboots:**

> **Note:** Container Insights only collects `Warning` events by default.
> Normal pod scheduling events (`Scheduled`, `Pulled`, `Started`) are not captured.
> The query below shows warning-level events that occur during node reboots.

```kql
KubeEvents
| where TimeGenerated > ago(4h)
| where Namespace in ("demo", "kube-system", "")
| where Reason in ("NodeNotReady", "Rebooted", "KubeletIsDown", "Killing",
                   "FailedScheduling", "Unhealthy", "FailedMount",
                   "FailedCreatePodSandBox", "ContainerdStart")
| project TimeGenerated, Namespace, Name, Reason, Message, ObjectKind
| order by TimeGenerated asc
```

**Kured container logs:**

> **Note:** `kube-system` logs require the DCR to be configured with
> `namespaceFilteringMode: Include` and `kube-system` in the namespaces list.
> After deploying with `deploy.yml`, allow 5--10 minutes for the agent to start
> collecting.

```kql
ContainerLogV2
| where TimeGenerated > ago(4h)
| where PodNamespace == "kube-system"
| where PodName startswith "kured-"
| project TimeGenerated, PodName, LogMessage
| order by TimeGenerated asc
```

**Reboot count per node (distinct boot IDs):**

```kql
KubeEvents
| where TimeGenerated > ago(24h)
| where Reason == "Rebooted"
| extend BootId = extract("boot id: ([a-f0-9-]+)", 1, Message)
| summarize Reboots = dcount(BootId), LastReboot = max(TimeGenerated) by Name
| order by Name asc
```

**Verify zero gaps in application availability:**

```kql
ContainerLogV2
| where TimeGenerated > ago(4h)
| where PodNamespace == "demo"
| where PodName startswith "zero-downtime-web"
| summarize Count = count() by bin(TimeGenerated, 1m)
| order by TimeGenerated asc
```

## Cleanup

### Option A: GitHub Actions

Trigger the `teardown.yml` workflow and type `DELETE` to confirm. The workflow deletes the entire resource group (`rg-aks-kured-poc`) and all resources within it. It also **disables the test workflow schedule** to prevent failed cron runs.

### Option B: Azure CLI

```bash
az group delete --name rg-aks-kured-poc --yes --no-wait
```

To wait for deletion to complete:

```bash
az group wait --deleted --resource-group rg-aks-kured-poc --timeout 1800
```

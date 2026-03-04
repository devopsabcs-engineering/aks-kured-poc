---
title: Kured Configuration Research for AKS Zero-Downtime Node Reboots
description: Comprehensive research on Kured (KUbernetes REboot Daemon) installation, configuration, PDB integration, and monitoring for AKS node reboot management
author: researcher-subagent
ms.date: 2026-03-04
ms.topic: reference
keywords:
  - kured
  - aks
  - node reboot
  - zero downtime
  - helm
  - PodDisruptionBudget
estimated_reading_time: 15
---

## Overview

### What is Kured?

Kured (KUbernetes REboot Daemon) is a CNCF Sandbox project that performs safe, automatic node reboots in Kubernetes clusters when the underlying OS signals that a reboot is needed. It deploys as a DaemonSet, running one pod on every Linux node in the cluster.

Kured solves a specific operational gap: Linux security and kernel updates are applied automatically on AKS nodes (via unattended upgrades), but some updates require a node reboot to take effect. AKS does not automatically reboot nodes. Without Kured, operators must manually SSH into nodes and reboot them, or leave nodes in a partially-patched state.

### How Kured Detects a Reboot Is Needed

On Ubuntu-based AKS nodes, the package manager creates a sentinel file at `/var/run/reboot-required` when an installed update requires a reboot (typically kernel updates). Kured polls for the existence of this file at a configurable interval (default: 60 minutes).

Alternatively, Kured can run a sentinel command. If the command exits with code `0`, Kured treats the node as requiring a reboot. This is useful for RHEL/CentOS derivatives where `needs-restarting --reboothint` indicates reboot necessity.

### Reboot Process (Step by Step)

1. Kured detects the sentinel file (`/var/run/reboot-required`) on a node.
2. Kured acquires a cluster-wide lock (annotation on the DaemonSet resource) to ensure only one node reboots at a time.
3. Kured cordons the node (marks it `SchedulingDisabled`).
4. Kured drains the node using the equivalent of `kubectl drain` (respecting PodDisruptionBudgets and graceful termination).
5. Kured reboots the node (default: `/bin/systemctl reboot`).
6. After the node comes back up, Kured uncordons it.
7. Kured releases the cluster-wide lock, allowing the next node to proceed.

### Key Properties

| Property              | Value                                                                 |
|-----------------------|-----------------------------------------------------------------------|
| Project               | CNCF Sandbox                                                          |
| Repository            | <https://github.com/kubereboot/kured>                                 |
| Documentation         | <https://kured.dev/docs/>                                             |
| Current version       | 1.21.0 (app), Helm chart 5.11.0                                      |
| Container image       | `ghcr.io/kubereboot/kured:1.21.0`                                    |
| Language              | Go                                                                    |
| License               | Apache-2.0                                                            |
| Kubernetes compat     | 1.33.x, 1.34.x, 1.35.x (for Kured 1.21.0)                           |
| Community             | CNCF Slack `#kured`, monthly meetings, mailing list                   |

## Installation on AKS

### Helm Chart Installation (Recommended)

The official Helm chart is maintained in the `kubereboot` organization. The chart repository URL and OCI registry both work.

```bash
# Add the Kured Helm repository
helm repo add kubereboot https://kubereboot.github.io/charts/

# Update local chart cache
helm repo update

# Create a dedicated namespace
kubectl create namespace kured

# Install Kured (restrict to Linux nodes only, since Kured does not support Windows)
helm install kured kubereboot/kured \
  --namespace kured \
  --set controller.nodeSelector."kubernetes\.io/os"=linux
```

Alternatively, install from the OCI registry:

```bash
helm install kured oci://ghcr.io/kubereboot/charts/kured \
  --namespace kured \
  --create-namespace
```

### Manifest-Based Installation

For environments where Helm is not used:

```bash
latest=$(curl -s https://api.github.com/repos/kubereboot/kured/releases | jq -r '.[0].tag_name')
kubectl apply -f "https://github.com/kubereboot/kured/releases/download/$latest/kured-$latest-combined.yaml"
```

### Helm Chart Coordinates

| Field            | Value                                    |
|------------------|------------------------------------------|
| Repo name        | `kubereboot`                             |
| Repo URL         | `https://kubereboot.github.io/charts/`   |
| Chart name       | `kured`                                  |
| OCI registry     | `ghcr.io/kubereboot/charts/kured`        |
| ArtifactHub page | <https://artifacthub.io/packages/helm/kured/kured> |

## Reboot Window and Disruption Control

### Schedule Configuration

By default, Kured reboots any time it detects the sentinel. Use these flags to restrict reboots to a maintenance window:

| Flag             | Default            | Purpose                                    |
|------------------|--------------------|--------------------------------------------|
| `--reboot-days`  | `su,mo,tu,we,th,fr,sa` | Days of the week when reboots are allowed |
| `--start-time`   | `0:00`             | Earliest time of day for reboots           |
| `--end-time`     | `23:59:59`         | Latest time of day for reboots             |
| `--time-zone`    | `UTC`              | Timezone for schedule (Go `time.Location`) |
| `--period`       | `1h0m0s`           | How often Kured checks for the sentinel    |

Example: Allow reboots only on weeknights between 11 PM and 5 AM Eastern time:

```yaml
configuration:
  rebootDays:
    - mo
    - tu
    - we
    - th
    - fr
  startTime: "11pm"
  endTime: "5am"
  timeZone: "America/New_York"
  period: "15m"
```

> [!IMPORTANT]
> When using a narrow maintenance window, reduce the `--period` value (e.g., `15m` or `10m`) so that the sentinel check happens frequently enough to act within the window.

Time formats accepted: `5pm`, `5:00pm`, `17:00`, `17`.

Timezone values: `UTC`, `Local`, or any entry in the standard Linux tz database (e.g., `America/Los_Angeles`, `Europe/London`).

### Cluster-Wide Lock Mechanism

Kured uses a Kubernetes annotation on the DaemonSet resource as a distributed lock:

* Default annotation: `weave.works/kured-node-lock`
* Only one Kured pod can hold the lock at any time, ensuring sequential node reboots.
* Each Kured pod uses a random offset derived from the period on startup, preventing simultaneous lock contention.
* The `--lock-ttl` flag sets an automatic expiry (e.g., `--lock-ttl=30m`) to handle scenarios where a node holding the lock fails permanently.
* The `--lock-release-delay` flag introduces a throttle delay between sequential reboots (e.g., `--lock-release-delay=5m`).

### Operational Lock Commands

Temporarily disable all reboots by manually acquiring the lock:

```bash
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock='{"nodeID":"manual"}'
```

Release the manual lock:

```bash
kubectl -n kube-system annotate ds kured weave.works/kured-node-lock-
```

> [!NOTE]
> The trailing `-` in the release command instructs `kubectl` to remove the annotation entirely.

## PodDisruptionBudgets (PDBs) and Zero-Downtime Drains

### How Kured Interacts with PDBs

When Kured drains a node, it performs the equivalent of `kubectl drain`. This operation respects PodDisruptionBudgets. If a PDB would be violated by evicting a pod, the drain blocks until the budget allows eviction (or the drain times out).

### PDB Best Practices for Zero-Downtime

For a workload with `N` replicas spread across `M` nodes:

* Set `minAvailable` to ensure at least one replica always stays running during node drains.
* For a 3-replica deployment, use `minAvailable: 2` or `maxUnavailable: 1`.
* Ensure replicas are distributed across nodes using pod anti-affinity rules.

Example PDB for a sample workload:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: sample-app-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: sample-app
```

Example pod anti-affinity (in the Deployment spec):

```yaml
spec:
  template:
    spec:
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
                        - sample-app
                topologyKey: kubernetes.io/hostname
```

### Drain Configuration in Kured

| Flag                           | Default | Purpose                                              |
|--------------------------------|---------|------------------------------------------------------|
| `--drain-grace-period`         | `-1`    | Seconds for graceful pod termination (-1 = pod default) |
| `--drain-timeout`              | `0`     | Maximum drain duration (0 = infinite)                |
| `--drain-delay`                | `0`     | Delay before starting drain                          |
| `--drain-pod-selector`         | `""`    | Only drain pods matching this selector               |
| `--skip-wait-for-delete-timeout` | `""`  | Skip waiting for pods older than N seconds           |
| `--force-reboot`               | `false` | Force reboot even if drain fails or times out        |

> [!WARNING]
> Setting `--force-reboot=true` bypasses PDB protections. Avoid this in production unless you have strong operational justification.

## Kured + AKS Node Image Updates

### The Unattended Upgrades + Kured Approach

The Microsoft-documented approach (see [Apply security and kernel updates to Linux nodes in AKS](https://learn.microsoft.com/en-us/azure/aks/node-updates-kured)) works as follows:

1. AKS Linux nodes use Ubuntu with automatic daily security updates (unattended-upgrades).
2. When a security or kernel update requires a reboot, the OS creates `/var/run/reboot-required`.
3. Kured detects this file and orchestrates a safe, sequential reboot (cordon, drain, reboot, uncordon).
4. The node comes back up with the updated kernel applied.

This approach patches existing nodes in-place. It does not update the node image used when scaling the node pool.

### Node Image Upgrades (Complementary)

`az aks nodepool upgrade --node-image-only` replaces the entire OS image of the node, using a cordon-drain-replace strategy managed by AKS itself (not Kured). It ensures new nodes also have the latest patches baked in.

| Aspect               | Unattended Upgrades + Kured               | Node Image Upgrade                      |
|----------------------|--------------------------------------------|-----------------------------------------|
| What it updates      | OS packages on existing nodes              | Entire OS image (new VMs)               |
| Reboot mechanism     | Kured (cordon, drain, reboot)              | AKS (cordon, drain, delete, new node)   |
| When to use          | Continuous daily security patching         | Periodic base image refresh             |
| Node identity        | Same VM, same node                         | New VM, new node                        |
| Scale-out impact     | New nodes still use old image              | New nodes use updated image             |

> [!TIP]
> Use both approaches together: unattended upgrades + Kured for daily security patches, and periodic node image upgrades to refresh the base image.

### Manual Reboot Testing

To validate Kured is working, SSH to a node and create the sentinel file:

```bash
sudo touch /var/run/reboot-required
```

Or apply pending updates manually:

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

Kured checks for nodes requiring a reboot every 60 minutes by default (configurable via `--period`).

## Notifications and Monitoring

### Notification Integrations

Kured supports notifications via the `--notify-url` flag using the [Shoutrrr](https://containrrr.dev/shoutrrr/v0.7/services/overview) library:

| Service      | URL Format                                                                                               |
|--------------|----------------------------------------------------------------------------------------------------------|
| Slack        | `slack://tokenA/tokenB/tokenC` or `slack://xoxb:token@channel?botname=kured`                            |
| Rocket.Chat  | `rocketchat://[username@]host/token[/channel]`                                                           |
| Teams        | `teams://group@tenant/altId/groupOwner?host=organization.webhook.office.com`                             |
| Email (SMTP) | `smtp://username:password@host:port/?fromAddress=sender&toAddresses=recipient1,recipient2`               |

Custom message templates:

```yaml
configuration:
  notifyUrl: "slack://xoxb:your-token@your-channel?botname=kured"
  messageTemplateDrain: "Draining node %s in *aks-kured-poc* cluster"
  messageTemplateReboot: "Rebooting node %s in *aks-kured-poc* cluster"
  messageTemplateUncordon: "Node %s rebooted & uncordoned in *aks-kured-poc* cluster"
```

> [!NOTE]
> The `--slack-hook-url` and `--slack-channel` flags are deprecated. Use `--notify-url` with the Slack URL format instead.

### Prometheus Metrics

Each Kured pod exposes a gauge metric on `:8080/metrics`:

```text
# HELP kured_reboot_required OS requires reboot due to software updates.
# TYPE kured_reboot_required gauge
kured_reboot_required{node="aks-nodepool1-12345678-vmss000000"} 0
```

Value `1` means the node requires a reboot; `0` means no reboot is pending.

### Recommended Prometheus Alert

Create a `RebootRequired` alert to catch situations where Kured cannot reboot nodes automatically:

```yaml
groups:
  - name: kured
    rules:
      - alert: RebootRequired
        expr: max(kured_reboot_required) != 0
        for: 24h
        labels:
          severity: warning
        annotations:
          summary: "Node(s) require reboot for over 24 hours"
          description: "One or more nodes require a reboot, and Kured has not completed it within 24 hours."
```

> [!IMPORTANT]
> If you configure Kured to block reboots when Prometheus alerts are firing (`--prometheus-url`), you must exclude the `RebootRequired` alert using `--alert-filter-regexp=^RebootRequired$` to avoid a deadlock where the alert blocks the very reboot it is reporting.

### Prometheus ServiceMonitor

Enable the ServiceMonitor for prometheus-operator-based stacks:

```yaml
metrics:
  create: true
  labels:
    release: kube-prometheus-stack
  interval: 60s

service:
  create: true
  port: 8080
```

### Blocking Reboots via Prometheus Alerts

Point Kured at your Prometheus instance to block reboots when critical alerts are firing:

```yaml
configuration:
  prometheusUrl: "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
  alertFilterRegexp: "^RebootRequired$"
  alertFiringOnly: true
```

## Helm Chart Values Reference

### Complete Production-Ready Values Example

```yaml
# kured-values.yaml
configuration:
  # Schedule: reboot only on weekdays between 2 AM and 5 AM UTC
  rebootDays:
    - mo
    - tu
    - we
    - th
    - fr
  startTime: "2am"
  endTime: "5am"
  timeZone: "UTC"

  # Check for sentinel every 15 minutes
  period: "15m"

  # Sentinel file (default for Ubuntu)
  # rebootSentinel: "/var/run/reboot-required"

  # Drain configuration
  drainGracePeriod: "60"
  drainTimeout: "300s"

  # Lock safety
  lockTtl: "30m"
  lockReleaseDelay: "5m"

  # Prometheus integration (optional)
  # prometheusUrl: "http://prometheus.monitoring.svc.cluster.local:9090"
  # alertFilterRegexp: "^RebootRequired$"
  # alertFiringOnly: true

  # Notifications (optional)
  # notifyUrl: "slack://xoxb:token@channel?botname=kured"
  # messageTemplateDrain: "Draining node %s"
  # messageTemplateReboot: "Rebooting node %s"
  # messageTemplateUncordon: "Node %s rebooted & uncordoned"

  # Annotate nodes with reboot status
  annotateNodes: true

  # Concurrency (keep at 1 for production zero-downtime)
  concurrency: 1

  # Logging
  logFormat: "text"

# Metrics and monitoring
metrics:
  create: true
  labels:
    release: kube-prometheus-stack
  interval: 60s

service:
  create: true
  port: 8080

# Node selector (Linux only; Kured does not support Windows)
nodeSelector:
  kubernetes.io/os: linux

# Tolerations (allow running on control-plane nodes if needed)
tolerations:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule

# Resource limits
resources:
  requests:
    cpu: 10m
    memory: 32Mi
  limits:
    cpu: 50m
    memory: 64Mi
```

Install with these values:

```bash
helm install kured kubereboot/kured \
  --namespace kured \
  --create-namespace \
  -f kured-values.yaml
```

### Key Helm Values Summary Table

| Helm Value                                | CLI Flag                   | Default                          | Description                                      |
|-------------------------------------------|----------------------------|----------------------------------|--------------------------------------------------|
| `configuration.rebootDays`                | `--reboot-days`            | `[su,mo,tu,we,th,fr,sa]`        | Days when reboots are allowed                    |
| `configuration.startTime`                 | `--start-time`             | `0:00`                           | Earliest time for reboots                        |
| `configuration.endTime`                   | `--end-time`               | `23:59:59`                       | Latest time for reboots                          |
| `configuration.timeZone`                  | `--time-zone`              | `UTC`                            | Timezone for schedule                            |
| `configuration.period`                    | `--period`                 | `1h0m0s`                         | Sentinel check interval                          |
| `configuration.rebootSentinel`            | `--reboot-sentinel`        | `/var/run/reboot-required`       | Path to sentinel file                            |
| `configuration.rebootSentinelCommand`     | `--reboot-sentinel-command`| `""`                             | Command-based sentinel (overrides file)          |
| `configuration.rebootCommand`             | `--reboot-command`         | `/bin/systemctl reboot`          | Reboot command                                   |
| `configuration.prometheusUrl`             | `--prometheus-url`         | `""`                             | Prometheus URL for alert checking                |
| `configuration.alertFilterRegexp`         | `--alert-filter-regexp`    | `""`                             | Regex to ignore specific alerts                  |
| `configuration.alertFiringOnly`           | `--alert-firing-only`      | `false`                          | Only consider firing (not pending) alerts        |
| `configuration.slackChannel`              | `--slack-channel`          | `""`                             | Slack channel (deprecated)                       |
| `configuration.slackHookUrl`              | `--slack-hook-url`         | `""`                             | Slack webhook URL (deprecated)                   |
| `configuration.notifyUrl`                 | `--notify-url`             | `""`                             | Shoutrrr notification URL                        |
| `configuration.messageTemplateDrain`      | `--message-template-drain` | `"Draining node %s"`            | Custom drain notification template               |
| `configuration.messageTemplateReboot`     | `--message-template-reboot`| `"Rebooting node %s"`           | Custom reboot notification template              |
| `configuration.messageTemplateUncordon`   | `--message-template-uncordon`| `"Node %s rebooted & uncordoned successfully!"` | Custom uncordon notification template |
| `configuration.blockingPodSelector`       | `--blocking-pod-selector`  | `[]`                             | Labels of pods that block reboots                |
| `configuration.drainGracePeriod`          | `--drain-grace-period`     | `-1`                             | Graceful termination seconds                     |
| `configuration.drainTimeout`              | `--drain-timeout`          | `0`                              | Max drain duration                               |
| `configuration.drainDelay`                | `--drain-delay`            | `0`                              | Delay before draining                            |
| `configuration.forceReboot`               | `--force-reboot`           | `false`                          | Force reboot on drain failure                    |
| `configuration.lockTtl`                   | `--lock-ttl`               | `0`                              | Lock expiry duration                             |
| `configuration.lockReleaseDelay`          | `--lock-release-delay`     | `0`                              | Delay before releasing lock                      |
| `configuration.lockAnnotation`            | `--lock-annotation`        | `weave.works/kured-node-lock`   | Annotation name for lock                         |
| `configuration.annotateNodes`             | `--annotate-nodes`         | `false`                          | Add reboot status annotations to nodes           |
| `configuration.concurrency`               | `--concurrency`            | `1`                              | Max concurrent reboots                           |
| `configuration.preferNoScheduleTaint`     | `--prefer-no-schedule-taint`| `""`                            | Taint applied during pending reboot              |
| `configuration.preRebootNodeLabels`       | `--pre-reboot-node-labels` | `[]`                             | Labels added before cordoning                    |
| `configuration.postRebootNodeLabels`      | `--post-reboot-node-labels`| `[]`                             | Labels added after uncordoning                   |
| `configuration.logFormat`                 | `--log-format`             | `text`                           | Log format (text or json)                        |
| `metrics.create`                          | N/A                        | `false`                          | Create ServiceMonitor for prometheus-operator     |
| `metrics.labels`                          | N/A                        | `{}`                             | Labels for ServiceMonitor discovery              |
| `metrics.interval`                        | N/A                        | `60s`                            | Prometheus scrape interval                       |
| `service.create`                          | N/A                        | `false`                          | Create Service for metrics endpoint              |
| `service.port`                            | N/A                        | `8080`                           | Metrics service port                             |

## References

* Kured GitHub: <https://github.com/kubereboot/kured>
* Kured documentation: <https://kured.dev/docs/>
* Kured configuration: <https://kured.dev/docs/configuration/>
* Kured installation: <https://kured.dev/docs/installation/>
* Kured operation: <https://kured.dev/docs/operation/>
* Kured Helm chart on ArtifactHub: <https://artifacthub.io/packages/helm/kured/kured>
* Helm chart source: <https://github.com/kubereboot/charts/tree/main/charts/kured>
* Microsoft AKS + Kured docs: <https://learn.microsoft.com/en-us/azure/aks/node-updates-kured>
* AKS node image upgrades: <https://learn.microsoft.com/en-us/azure/aks/node-image-upgrade>
* Shoutrrr notifications: <https://containrrr.dev/shoutrrr/v0.7/services/overview>
* CNCF Slack `#kured`: <https://cloud-native.slack.com/archives/kured>

## Remaining Questions

* Should the POC use Azure Linux 3 or Ubuntu as the node OS? Azure Linux 2.0 is being retired (removed March 31, 2026). The sentinel file mechanism (`/var/run/reboot-required`) is Ubuntu-specific; Azure Linux may use a different mechanism or require a sentinel command.
* What Kubernetes version will the AKS cluster run? Kured 1.21.0 supports 1.33.x through 1.35.x.
* Should Prometheus/Grafana be deployed as part of the POC for monitoring, or rely on Container Insights?
* Is Slack or Teams the preferred notification channel for reboot events?
* Should the POC also demonstrate `az aks nodepool upgrade --node-image-only` alongside Kured, or focus exclusively on Kured + unattended upgrades?

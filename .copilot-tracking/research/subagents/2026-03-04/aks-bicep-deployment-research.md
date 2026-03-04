---
title: AKS Bicep Deployment Research for Kured Zero-Downtime POC
description: Comprehensive research on deploying an AKS cluster with Bicep, covering resource definitions, node pool configuration, auto-upgrade channels, supporting resources, Container Insights, and complete code examples
author: researcher-subagent
ms.date: 2026-03-04
ms.topic: reference
keywords:
  - aks
  - bicep
  - kured
  - zero-downtime
  - container insights
  - node reboot
estimated_reading_time: 20
---
<!-- markdownlint-disable-file -->

## Overview

This document captures in-depth research on deploying an Azure Kubernetes Service (AKS) cluster using Bicep templates, tailored specifically for a Kured zero-downtime node reboot POC. The cluster uses 3 Linux (Ubuntu) nodes, SystemAssigned managed identity, Container Insights monitoring, and an auto-upgrade channel configured for Kured-managed reboots.

## 1. AKS Bicep Resource Definition

### Resource Type

The primary resource type is `Microsoft.ContainerService/managedClusters` at API version `2024-09-01` (or newer). This resource represents the entire AKS cluster, including its control plane configuration, identity, networking, and default node pool.

### Key Properties

| Property                         | Description                                                                                          |
|----------------------------------|------------------------------------------------------------------------------------------------------|
| `location`                       | Azure region for the cluster (e.g., `eastus2`, `canadacentral`).                                     |
| `identity`                       | Managed identity configuration. Use `SystemAssigned` for simplicity.                                 |
| `properties.dnsPrefix`           | Unique DNS prefix for the cluster's FQDN.                                                           |
| `properties.kubernetesVersion`   | Target Kubernetes version (e.g., `1.29`). Omit to use the default latest stable version.            |
| `properties.agentPoolProfiles`   | Array defining node pools. At least one system pool is required.                                     |
| `properties.networkProfile`      | Network plugin, policy, service CIDR, DNS service IP.                                                |
| `properties.addonProfiles`       | Add-on configurations including Container Insights (`omsagent`).                                     |
| `properties.autoUpgradeProfile`  | Cluster-level upgrade channel (`none`, `patch`, `stable`, `rapid`, `node-image`).                    |
| `properties.nodeOSUpgradeChannel`| Controls how node OS updates are applied (`None`, `Unmanaged`, `SecurityPatch`, `NodeImage`).        |

### Identity Configuration

For a POC environment, `SystemAssigned` managed identity is the simplest option. It avoids the need to pre-create a user-assigned identity or manage service principal credentials.

```bicep
identity: {
  type: 'SystemAssigned'
}
```

The system-assigned identity is created automatically when the cluster is provisioned and deleted when the cluster is removed.

## 2. Node Pool Configuration

### System Node Pool Requirements

Every AKS cluster needs at least one system node pool to run core system pods (CoreDNS, metrics-server, etc.). For this POC, a single system pool with 3 nodes is sufficient.

### Key Agent Pool Properties

| Property            | Value / Recommendation                                  | Notes                                                            |
|---------------------|---------------------------------------------------------|------------------------------------------------------------------|
| `name`              | `systempool` (max 12 chars for Linux)                   | Lowercase alphanumeric only.                                     |
| `count`             | `3`                                                     | Provides fault tolerance during rolling reboots.                 |
| `vmSize`            | `Standard_DS2_v2` or `Standard_B2ms`                    | Cost-effective for POC. DS2_v2 offers consistent performance.    |
| `osType`            | `Linux`                                                 | Required for Kured (Linux-only).                                 |
| `osSKU`             | `Ubuntu` (default) or `AzureLinux`                      | Ubuntu is the proven choice for Kured unattended-upgrades.       |
| `mode`              | `System`                                                | Marks the pool as a system node pool.                            |
| `osDiskSizeGB`      | `30` (or default `128`)                                 | 30 GB saves cost for POC; sufficient for system workloads.       |
| `osDiskType`        | `Ephemeral` or `Managed`                                | Ephemeral provides faster node reimaging; requires VM SKU support.|
| `maxPods`           | `110` (default)                                         | Default is fine for POC.                                         |
| `type`              | `VirtualMachineScaleSets`                               | Required for multi-node pools and cluster autoscaler.            |
| `availabilityZones` | `['1', '2', '3']` (optional)                            | Spreads nodes across zones for HA. Optional for POC.            |

### Ephemeral OS Disk Considerations

Ephemeral OS disks use the VM's local SSD/NVMe storage rather than remote Azure managed disks. Benefits for this POC include:

* Faster node reimaging and scaling operations
* Lower latency for OS disk I/O
* No additional managed disk cost

The VM size must support ephemeral OS disks. `Standard_DS2_v2` supports ephemeral disks with a cache size of 86 GiB. Set `osDiskType: 'Ephemeral'` and keep `osDiskSizeGB` within the cache size limit.

> [!NOTE]
> Ephemeral OS disks lose data on deallocation or reimaging. This is acceptable for AKS nodes since they are stateless by design.

### Complete Agent Pool Profile

```bicep
agentPoolProfiles: [
  {
    name: 'systempool'
    count: nodeCount
    vmSize: vmSize
    osType: 'Linux'
    osSKU: 'Ubuntu'
    mode: 'System'
    osDiskSizeGB: 30
    osDiskType: 'Ephemeral'
    type: 'VirtualMachineScaleSets'
    maxPods: 110
  }
]
```

## 3. AKS Auto-Upgrade Channels and Node OS Upgrade

### Cluster Auto-Upgrade Channel

The `autoUpgradeProfile.upgradeChannel` controls how the Kubernetes version itself is upgraded:

| Channel      | Behavior                                                                            |
|--------------|-------------------------------------------------------------------------------------|
| `none`       | No automatic Kubernetes version upgrades.                                           |
| `patch`      | Auto-upgrades to the latest supported patch version within the current minor.       |
| `stable`     | Auto-upgrades to the latest patch of the N-1 minor version.                         |
| `rapid`      | Auto-upgrades to the latest supported patch of the latest supported minor.          |
| `node-image` | Auto-upgrades node images to the latest available version (weekly).                 |

For the Kured POC, set this to `patch` or `none`. You want Kubernetes patches applied but node OS reboots controlled by Kured, not by automatic node image upgrades.

### Node OS Upgrade Channel (Critical for Kured)

The `autoUpgradeProfile.nodeOSUpgradeChannel` property (API version `2023-08-01` and newer) determines how the underlying node OS handles security patches:

| Channel         | Behavior                                                                                                | Kured Compatibility |
|-----------------|---------------------------------------------------------------------------------------------------------|---------------------|
| `None`          | No automatic OS updates. You must manage updates manually or via a custom solution.                     | Compatible but requires manual trigger. |
| `Unmanaged`     | The OS uses its built-in update mechanism (e.g., `unattended-upgrades` on Ubuntu). Updates apply in-place and flag `/var/run/reboot-required` when a reboot is needed. Kured detects this sentinel file and orchestrates the reboot. | Best for Kured. |
| `SecurityPatch` | AKS applies security patches to nodes without reimaging. May reboot nodes automatically.                | Conflicts with Kured. |
| `NodeImage`     | AKS fully reimages nodes to the latest node image. Replaces the entire OS disk.                         | Replaces Kured's role. |

> [!IMPORTANT]
> For a Kured-based approach, set `nodeOSUpgradeChannel` to `Unmanaged`. This allows Ubuntu's `unattended-upgrades` to install security patches, which creates the `/var/run/reboot-required` sentinel file. Kured monitors this file and performs a cordon-drain-reboot-uncordon cycle on each node sequentially, ensuring zero downtime.

### How Kured Integrates with Unmanaged Updates

The flow works as follows:

1. Ubuntu's `unattended-upgrades` runs daily (configurable) and installs available security patches.
2. When a kernel or critical library update requires a reboot, the system creates `/var/run/reboot-required`.
3. Kured (running as a DaemonSet on every node) polls for this sentinel file.
4. When detected, Kured acquires a cluster-wide lock (via the Kubernetes API) to ensure only one node reboots at a time.
5. Kured cordons the node (prevents new pod scheduling), drains it (evicts pods respecting PodDisruptionBudgets), reboots, and then uncordons it.
6. Once the node is healthy and ready, Kured releases the lock and the next node (if also needing reboot) proceeds.

### Recommended Configuration

```bicep
autoUpgradeProfile: {
  upgradeChannel: 'patch'
  nodeOSUpgradeChannel: 'Unmanaged'
}
```

## 4. Supporting Azure Resources

### Required Resources

| Resource                    | Purpose                                                    | Required? |
|-----------------------------|------------------------------------------------------------|-----------|
| Resource group              | Logical container for all POC resources.                   | Yes       |
| Log Analytics workspace     | Backend for Container Insights telemetry.                  | Yes (for monitoring) |
| AKS managed cluster         | The Kubernetes cluster itself.                             | Yes       |

### Optional Resources

| Resource                    | Purpose                                                    | When Needed |
|-----------------------------|------------------------------------------------------------|-------------|
| Virtual network / subnet    | Custom networking (Azure CNI). Default kubenet works.      | For production or advanced networking scenarios. |
| Azure Container Registry    | Private container image registry.                          | If you host custom images. Not needed for Kured (pulled from ghcr.io). |
| Azure Key Vault             | Store secrets, certificates.                               | If the sample workload needs secrets. |
| Public IP / DNS zone        | External access to services.                               | If exposing services publicly. |

### Resource Group

Deploy the resource group via Azure CLI or a separate Bicep module. AKS creates a second "node resource group" (named `MC_<rg>_<cluster>_<region>`) automatically to hold the VMSS, disks, and load balancers.

```bicep
targetScope = 'subscription'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}
```

### Log Analytics Workspace

Container Insights requires a Log Analytics workspace to receive telemetry data:

```bicep
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}
```

The `PerGB2018` SKU is the current standard pricing tier. A 30-day retention period is cost-effective for a POC.

## 5. Container Insights / Monitoring

### Enabling Container Insights via Bicep

Container Insights is enabled through the `omsagent` addon profile on the AKS resource. It requires a Log Analytics workspace ID.

```bicep
addonProfiles: {
  omsagent: {
    enabled: true
    config: {
      logAnalyticsWorkspaceResourceID: logAnalyticsWorkspace.id
    }
  }
}
```

### What Container Insights Provides

* Node-level CPU, memory, disk, and network metrics
* Pod and container resource utilization
* Kubernetes event logs
* Container stdout/stderr logs
* Cluster health and readiness monitoring
* Workbook-based dashboards in the Azure portal

### Monitoring Kured Reboots

With Container Insights enabled, you can query Kured activity through:

* KQL queries in Log Analytics to find node reboot events
* Kubernetes events showing cordon/drain/uncordon operations
* Pod restart counts and node readiness transitions

Example KQL query to detect node reboots:

```kql
KubeNodeInventory
| where TimeGenerated > ago(24h)
| where Status == "NotReady"
| project TimeGenerated, Computer, Status
| order by TimeGenerated desc
```

### Azure Monitor Metrics Addon (Optional)

For Prometheus-compatible metrics (useful for Grafana dashboards), enable the Azure Monitor metrics addon:

```bicep
azureMonitorMetrics: {
  enabled: true
}
```

This is optional for the POC but useful if you want Prometheus-based alerting on Kured behavior.

## 6. Bicep Parameters and Outputs

### Parameter Best Practices

* Provide sensible defaults for POC values to minimize required input.
* Use `@description` decorators for self-documentation.
* Use `@allowed` decorators to constrain values where appropriate.
* Use `@minLength` / `@maxLength` for string validation.
* Separate environment-specific values into a `.bicepparam` or JSON parameter file.

### Recommended Parameters

| Parameter             | Type   | Default                | Description                                    |
|-----------------------|--------|------------------------|------------------------------------------------|
| `location`            | string | `resourceGroup().location` | Azure region for all resources.            |
| `clusterName`         | string | (required)             | Name of the AKS cluster.                      |
| `dnsPrefix`           | string | (derived from cluster) | DNS prefix for the cluster FQDN.               |
| `kubernetesVersion`   | string | `'1.29'`               | Kubernetes version. Omit for default latest.   |
| `nodeCount`           | int    | `3`                    | Number of nodes in the system pool.            |
| `vmSize`              | string | `'Standard_DS2_v2'`    | VM size for nodes.                             |
| `logAnalyticsWorkspaceName` | string | (derived)        | Name for the Log Analytics workspace.          |

### Useful Outputs

| Output                | Value                                          | Use Case                                     |
|-----------------------|------------------------------------------------|----------------------------------------------|
| `clusterFqdn`        | Cluster's FQDN for API access                 | Configuring `kubectl` context.               |
| `clusterName`        | The deployed cluster name                      | Referencing in downstream scripts.           |
| `kubeletIdentityObjectId` | Kubelet identity's object ID              | Assigning RBAC roles (e.g., ACR pull).       |
| `nodeResourceGroup`  | MC_ resource group name                        | Referencing node-level resources.            |
| `controlPlaneFqdn`   | Control plane FQDN                             | DNS and connectivity validation.             |

## 7. Complete Bicep Template

### Main Template (`main.bicep`)

```bicep
// main.bicep
// AKS cluster deployment for Kured zero-downtime POC

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the AKS cluster.')
@minLength(3)
@maxLength(63)
param clusterName string

@description('DNS prefix for the AKS cluster FQDN.')
param dnsPrefix string = clusterName

@description('Kubernetes version. Leave empty for the default latest stable version.')
param kubernetesVersion string = ''

@description('Number of nodes in the system node pool.')
@minValue(1)
@maxValue(10)
param nodeCount int = 3

@description('VM size for the system node pool.')
param vmSize string = 'Standard_DS2_v2'

@description('OS disk size in GB. Use 30 for ephemeral disk POC.')
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

// ──────────────────────────────────────────────
// Log Analytics Workspace
// ──────────────────────────────────────────────

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

// ──────────────────────────────────────────────
// AKS Managed Cluster
// ──────────────────────────────────────────────

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
      nodeOSUpgradeChannel: 'Unmanaged'
    }
  }
}

// ──────────────────────────────────────────────
// Outputs
// ──────────────────────────────────────────────

@description('The FQDN of the AKS cluster control plane.')
output controlPlaneFqdn string = aksCluster.properties.fqdn

@description('The name of the AKS cluster.')
output clusterName string = aksCluster.name

@description('The resource ID of the AKS cluster.')
output clusterResourceId string = aksCluster.id

@description('The node resource group created by AKS.')
output nodeResourceGroup string = aksCluster.properties.nodeResourceGroup

@description('The object ID of the kubelet managed identity.')
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId

@description('The resource ID of the Log Analytics workspace.')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id
```

### Parameters File (`main.bicepparam`)

```bicep
using './main.bicep'

param clusterName = 'aks-kured-poc'
param location = 'eastus2'
param kubernetesVersion = '1.29'
param nodeCount = 3
param vmSize = 'Standard_DS2_v2'
param osDiskSizeGB = 30
param logAnalyticsWorkspaceName = 'aks-kured-poc-logs'
param logRetentionDays = 30
param tags = {
  project: 'aks-kured-poc'
  environment: 'poc'
  managedBy: 'bicep'
}
```

### Alternative JSON Parameters File (`main.parameters.json`)

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "clusterName": {
      "value": "aks-kured-poc"
    },
    "location": {
      "value": "eastus2"
    },
    "kubernetesVersion": {
      "value": "1.29"
    },
    "nodeCount": {
      "value": 3
    },
    "vmSize": {
      "value": "Standard_DS2_v2"
    },
    "osDiskSizeGB": {
      "value": 30
    },
    "logAnalyticsWorkspaceName": {
      "value": "aks-kured-poc-logs"
    },
    "logRetentionDays": {
      "value": 30
    },
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

### Deployment Commands

Deploy using Azure CLI:

```bash
# Create resource group
az group create \
  --name rg-aks-kured-poc \
  --location eastus2

# Deploy using .bicepparam file
az deployment group create \
  --resource-group rg-aks-kured-poc \
  --template-file main.bicep \
  --parameters main.bicepparam

# Or deploy using JSON parameters file
az deployment group create \
  --resource-group rg-aks-kured-poc \
  --template-file main.bicep \
  --parameters @main.parameters.json

# Get credentials for kubectl
az aks get-credentials \
  --resource-group rg-aks-kured-poc \
  --name aks-kured-poc
```

## 8. VM Size Comparison for POC

| VM Size            | vCPUs | Memory (GiB) | Temp Storage (GiB) | Ephemeral OS Support | Approx. Cost/mo (Pay-as-you-go) | Recommendation     |
|--------------------|-------|---------------|---------------------|----------------------|---------------------------------|--------------------|
| `Standard_B2ms`    | 2     | 8             | 16                  | No (cache too small) | ~$60                            | Cheapest. No ephemeral disk support. |
| `Standard_B2s_v2`  | 2     | 8             | 0                   | No                   | ~$55                            | Burstable, ephemeral not supported.  |
| `Standard_DS2_v2`  | 2     | 7             | 14                  | Yes (86 GiB cache)  | ~$100                           | Best balance for POC. Ephemeral disk supported. |
| `Standard_D2s_v5`  | 2     | 8             | 0                   | Yes (50 GiB cache)  | ~$70                            | Newer generation, good price/perf.   |
| `Standard_D2as_v5` | 2     | 8             | 0                   | Yes (50 GiB cache)  | ~$63                            | AMD-based, cost-effective.           |

> [!TIP]
> `Standard_DS2_v2` is the recommended default. It supports ephemeral OS disks, has consistent (non-burstable) performance, and is widely available across Azure regions. For a tighter budget, `Standard_D2as_v5` offers a newer AMD-based alternative at lower cost.

## 9. Network Configuration Options

### Kubenet (Default, Recommended for POC)

Kubenet is the default network plugin. Nodes receive IPs from the Azure VNet subnet, but pods use an overlay network with NAT for external communication.

* Simpler setup, no VNet planning required
* Suitable for POC environments
* Nodes get Azure VNet IPs; pods get IPs from a private CIDR

```bicep
networkProfile: {
  networkPlugin: 'kubenet'
  loadBalancerSku: 'standard'
}
```

### Azure CNI (Production Alternative)

Azure CNI assigns VNet IPs directly to pods. Better for production but requires subnet planning.

```bicep
networkProfile: {
  networkPlugin: 'azure'
  serviceCidr: '10.0.0.0/16'
  dnsServiceIP: '10.0.0.10'
  loadBalancerSku: 'standard'
}
```

For this POC, kubenet is sufficient and reduces complexity.

## 10. Validation and Pre-Deployment Checks

Before deploying, validate the Bicep template:

```bash
# Validate the template
az deployment group validate \
  --resource-group rg-aks-kured-poc \
  --template-file main.bicep \
  --parameters main.bicepparam

# What-if to preview changes
az deployment group what-if \
  --resource-group rg-aks-kured-poc \
  --template-file main.bicep \
  --parameters main.bicepparam

# Check available Kubernetes versions
az aks get-versions \
  --location eastus2 \
  --output table
```

## 11. Teardown

Complete resource cleanup with a single command:

```bash
az group delete --name rg-aks-kured-poc --yes --no-wait
```

This deletes all resources including the node resource group (`MC_*`), managed identities, and the Log Analytics workspace.

## Key Findings Summary

1. `nodeOSUpgradeChannel: 'Unmanaged'` is the critical setting that enables Kured's workflow. Ubuntu's `unattended-upgrades` installs patches and creates the reboot sentinel file; Kured detects it and orchestrates safe reboots.
2. Three nodes provide the minimum viable configuration for demonstrating zero-downtime reboots. While one node is rebooting, the remaining two continue serving workloads.
3. `Standard_DS2_v2` with ephemeral OS disks provides the best balance of cost, performance, and feature support for this POC.
4. Container Insights (via the `omsagent` addon) is essential for proving that zero downtime was achieved during the Kured reboot cycle.
5. The cluster auto-upgrade channel should be set to `patch` (for Kubernetes patches) while the node OS upgrade channel stays `Unmanaged` to let Kured handle reboots.
6. Kubenet networking is sufficient for the POC and avoids subnet planning complexity.
7. The complete Bicep template above is self-contained (cluster + Log Analytics workspace) and deployable with a single `az deployment group create` command.

## Remaining Questions

* Which Kubernetes version should be pinned? The template defaults to the AKS default, but specifying `1.29` or `1.30` ensures reproducibility. Check `az aks get-versions --location <region>` at deployment time.
* Should the POC use availability zones? Zones spread nodes across fault domains (improving resilience during reboots) but may incur cross-zone data transfer costs.
* Is a dedicated VNet needed for the POC, or is the AKS-managed VNet (with kubenet) sufficient? For isolation or peering requirements, a custom VNet module would be needed.
* Should Azure Container Registry be included in the Bicep template? The sample workload could use public images, avoiding ACR cost entirely.
* The `omsagent` addon name may change to `azureMonitorMetrics` or a combined monitoring addon in newer API versions. Verify against the target API version at deployment time.

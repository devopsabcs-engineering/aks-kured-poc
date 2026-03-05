@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Name of the AKS cluster.')
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
param vmSize string = 'Standard_D4s_v3'

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

// Data Collection Rule for Container Insights (Azure Monitor Agent)
// Must deploy after AKS — the omsagent addon creates the required tables in Log Analytics
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${clusterName}-dcr'
  location: location
  tags: tags
  dependsOn: [
    aksCluster
  ]
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: [
            'Microsoft-ContainerLogV2'
            'Microsoft-KubeEvents'
            'Microsoft-KubePodInventory'
            'Microsoft-KubeNodeInventory'
            'Microsoft-KubeServices'
            'Microsoft-Perf'
          ]
          extensionSettings: {
            dataCollectionSettings: {
              interval: '1m'
              namespaceFilteringMode: 'Include'
              namespaces: [
                'kube-system'
                'demo'
                'default'
              ]
              enableContainerLogV2: true
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          workspaceResourceId: logAnalyticsWorkspace.id
          name: 'ciworkspace'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-ContainerLogV2'
          'Microsoft-KubeEvents'
          'Microsoft-KubePodInventory'
          'Microsoft-KubeNodeInventory'
          'Microsoft-KubeServices'
          'Microsoft-Perf'
        ]
        destinations: [
          'ciworkspace'
        ]
      }
    ]
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
          useAADAuth: 'true'
        }
      }
    }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
      nodeOSUpgradeChannel: 'Unmanaged'  // Critical: lets unattended-upgrades + Kured handle reboots
    }
  }
}

// Associate DCR with AKS cluster
resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: '${clusterName}-dcra'
  scope: aksCluster
  properties: {
    dataCollectionRuleId: dataCollectionRule.id
  }
}

// Outputs
output controlPlaneFqdn string = aksCluster.properties.fqdn
output clusterName string = aksCluster.name
output clusterResourceId string = aksCluster.id
output nodeResourceGroup string = aksCluster.properties.nodeResourceGroup
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

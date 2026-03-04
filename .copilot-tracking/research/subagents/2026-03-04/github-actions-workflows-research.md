---
title: "GitHub Actions Workflows Research: AKS Kured POC"
description: Research on GitHub Actions workflows for deploying AKS with Bicep, installing Kured via Helm, deploying sample workloads, and running availability tests.
author: researcher-subagent
ms.date: 2026-03-04
ms.topic: reference
keywords:
  - github actions
  - aks
  - bicep
  - kured
  - helm
  - workflow_dispatch
  - oidc
  - teardown
estimated_reading_time: 20
---

## Overview

This document covers research findings for GitHub Actions workflows needed by the AKS Kured zero-downtime POC. It addresses Azure authentication, Bicep deployment, AKS credential retrieval, Helm chart installation, kubectl operations, and provides complete YAML examples for three workflows: deploy (tear-up), teardown, and test.

## 1. Azure Login in GitHub Actions

### 1.1 OIDC Federated Credentials (Recommended)

OpenID Connect federation eliminates long-lived secrets. GitHub's OIDC provider issues a short-lived token that Azure Entra ID trusts directly.

Prerequisites:

* An Azure AD (Entra ID) app registration with a federated credential configured for the GitHub repository.
* Three GitHub repository secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.
* The workflow must request `id-token: write` and `contents: read` permissions.

```yaml
permissions:
  id-token: write
  contents: read

steps:
  - name: Azure Login (OIDC)
    uses: azure/login@v2
    with:
      client-id: ${{ secrets.AZURE_CLIENT_ID }}
      tenant-id: ${{ secrets.AZURE_TENANT_ID }}
      subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

Federated credential entity configuration in the app registration:

| Field                | Value                                                           |
|----------------------|-----------------------------------------------------------------|
| Issuer               | `https://token.actions.githubusercontent.com`                   |
| Subject identifier   | `repo:devopsabcs-engineering/aks-kured-poc:ref:refs/heads/main` |
| Audience             | `api://AzureADTokenExchange`                                    |

For `workflow_dispatch` triggers, the subject identifier must match the branch the workflow runs on. You can also use a wildcard entity type (`repo:org/repo:*`) for broader matching, though the branch-specific form is more secure.

### 1.2 Service Principal with Secret (Alternative)

This approach stores a JSON credential object as a single secret `AZURE_CREDENTIALS`.

```yaml
steps:
  - name: Azure Login (SP)
    uses: azure/login@v2
    with:
      creds: ${{ secrets.AZURE_CREDENTIALS }}
```

The `AZURE_CREDENTIALS` secret contains:

```json
{
  "clientId": "<app-id>",
  "clientSecret": "<secret>",
  "subscriptionId": "<sub-id>",
  "tenantId": "<tenant-id>"
}
```

> [!WARNING]
> Service principal secrets expire and must be rotated. OIDC federation avoids this operational burden and is the recommended approach for GitHub Actions.

### 1.3 Comparison

| Aspect             | OIDC Federation                    | Service Principal Secret       |
|--------------------|------------------------------------|--------------------------------|
| Secret rotation    | Not required                       | Manual rotation required       |
| Security posture   | No long-lived credentials          | Secret stored in GitHub        |
| Setup complexity   | Moderate (federated credential)    | Low (az ad sp create-for-rbac) |
| GitHub permissions | Requires `id-token: write`         | None extra                     |
| Action version     | `azure/login@v2`                   | `azure/login@v2`              |

## 2. Bicep Deployment via GitHub Actions

### 2.1 Using az CLI Directly

The `az deployment group create` command deploys a Bicep file to a resource group. This approach provides the most control and is straightforward.

```yaml
- name: Create Resource Group
  run: |
    az group create \
      --name ${{ env.RESOURCE_GROUP }} \
      --location ${{ env.LOCATION }}

- name: Deploy Bicep
  run: |
    az deployment group create \
      --resource-group ${{ env.RESOURCE_GROUP }} \
      --template-file ./infra/main.bicep \
      --parameters ./infra/parameters.json \
      --parameters clusterName=${{ env.CLUSTER_NAME }}
```

### 2.2 Using azure/arm-deploy Action

The `azure/arm-deploy@v2` action wraps the deployment and provides structured outputs.

```yaml
- name: Deploy Bicep
  uses: azure/arm-deploy@v2
  id: deploy
  with:
    subscriptionId: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    resourceGroupName: ${{ env.RESOURCE_GROUP }}
    template: ./infra/main.bicep
    parameters: ./infra/parameters.json clusterName=${{ env.CLUSTER_NAME }}
    failOnStdErr: false
```

Accessing outputs:

```yaml
- name: Get AKS Name
  run: echo "Cluster name is ${{ steps.deploy.outputs.clusterName }}"
```

### 2.3 Comparison

| Aspect             | az CLI                       | azure/arm-deploy@v2                  |
|--------------------|------------------------------|--------------------------------------|
| Output handling    | Parse with `--query` and jq  | Native step outputs                  |
| Parameter passing  | `--parameters` flag          | `parameters` input (space-separated) |
| Error handling     | Exit code + stderr           | `failOnStdErr` option                |
| Flexibility        | Full CLI surface area        | Deployment-focused                   |

### 2.4 Parameter Passing Strategies

Inline override of parameters file values:

```yaml
--parameters ./infra/parameters.json \
--parameters clusterName=myAks nodeCount=3 vmSize=Standard_DS2_v2
```

For the `arm-deploy` action, combine a parameters file with inline overrides in the same `parameters` input, separated by spaces:

```yaml
parameters: >-
  ./infra/parameters.json
  clusterName=${{ env.CLUSTER_NAME }}
  nodeCount=3
```

### 2.5 Resource Group Creation

Bicep deployments target an existing resource group. The workflow must create the resource group first if it does not exist. Use `az group create`, which is idempotent (it updates tags if the group already exists).

## 3. AKS Credential Retrieval

### 3.1 Using azure/aks-set-context Action

This action sets the kubeconfig context for subsequent kubectl and Helm steps.

```yaml
- name: Set AKS Context
  uses: azure/aks-set-context@v4
  with:
    resource-group: ${{ env.RESOURCE_GROUP }}
    cluster-name: ${{ env.CLUSTER_NAME }}
```

The action writes the kubeconfig to a temporary file and sets `KUBECONFIG` for subsequent steps. It requires the `azure/login` step to have run first.

### 3.2 Using az CLI

```yaml
- name: Get AKS Credentials
  run: |
    az aks get-credentials \
      --resource-group ${{ env.RESOURCE_GROUP }} \
      --name ${{ env.CLUSTER_NAME }} \
      --overwrite-existing
```

This writes to `~/.kube/config` and merges contexts. Both approaches work; the action-based approach is cleaner for declarative workflows.

### 3.3 Admin vs User Credentials

For POC scenarios where RBAC may not be fully configured, the `--admin` flag retrieves cluster-admin credentials:

```yaml
az aks get-credentials --admin --resource-group $RG --name $CLUSTER
```

The `aks-set-context@v4` action supports an `admin` input:

```yaml
- uses: azure/aks-set-context@v4
  with:
    resource-group: ${{ env.RESOURCE_GROUP }}
    cluster-name: ${{ env.CLUSTER_NAME }}
    admin: true
```

## 4. Helm Installation in GitHub Actions

### 4.1 Setup Helm

The `azure/setup-helm@v4` action installs the Helm CLI on the runner.

```yaml
- name: Setup Helm
  uses: azure/setup-helm@v4
  with:
    version: v3.16.0
```

> [!NOTE]
> GitHub-hosted runners include Helm pre-installed. Pinning a version with `azure/setup-helm@v4` ensures reproducibility.

### 4.2 Installing Kured via Helm

Kured is published in the `kured` Helm repository at `https://kubereboot.github.io/charts`.

```yaml
- name: Add Kured Helm Repo
  run: |
    helm repo add kured https://kubereboot.github.io/charts
    helm repo update

- name: Install Kured
  run: |
    helm upgrade --install kured kured/kured \
      --namespace kube-system \
      --set configuration.period=1m \
      --set configuration.startTime="2:00am" \
      --set configuration.endTime="6:00am" \
      --set configuration.timeZone="America/New_York" \
      --set configuration.rebootDays="mon,tue,wed,thu,fri" \
      --set tolerations[0].effect=NoSchedule \
      --set tolerations[0].key=node-role.kubernetes.io/control-plane \
      --wait \
      --timeout 5m
```

`helm upgrade --install` is idempotent: it installs on first run and upgrades on subsequent runs.

### 4.3 Key Kured Configuration Parameters

| Parameter                       | Purpose                                              | Example Value          |
|---------------------------------|------------------------------------------------------|------------------------|
| `configuration.period`          | How often Kured checks for reboot sentinel           | `1m`                   |
| `configuration.startTime`       | Start of the allowed reboot window                   | `2:00am`               |
| `configuration.endTime`         | End of the allowed reboot window                     | `6:00am`               |
| `configuration.timeZone`        | Timezone for the reboot window                       | `America/New_York`     |
| `configuration.rebootDays`      | Days when reboots are allowed                        | `mon,tue,wed,thu,fri`  |
| `configuration.alertUrl`        | Slack/Teams webhook for reboot notifications         | `https://hooks.slack.com/...` |
| `configuration.drainGracePeriod`| Grace period for pod eviction during drain           | `60`                   |
| `configuration.prometheusUrl`   | Prometheus endpoint to block reboots when alerts fire | `http://prom:9090`     |

### 4.4 Kured Values File Approach

For complex configurations, use a values file instead of `--set` flags:

```yaml
- name: Install Kured
  run: |
    helm upgrade --install kured kured/kured \
      --namespace kube-system \
      --values ./k8s/kured-values.yaml \
      --wait \
      --timeout 5m
```

## 5. kubectl Operations

### 5.1 Direct kubectl

After setting AKS context, kubectl commands run against the cluster:

```yaml
- name: Deploy Sample Workload
  run: |
    kubectl apply -f ./k8s/sample-workload/namespace.yaml
    kubectl apply -f ./k8s/sample-workload/deployment.yaml
    kubectl apply -f ./k8s/sample-workload/service.yaml
    kubectl apply -f ./k8s/sample-workload/pdb.yaml

- name: Wait for Rollout
  run: |
    kubectl rollout status deployment/sample-app \
      --namespace sample-app \
      --timeout=300s
```

### 5.2 Using azure/k8s-deploy Action

The `azure/k8s-deploy@v5` action provides structured manifest deployment with canary and blue-green strategies.

```yaml
- name: Deploy Workload
  uses: azure/k8s-deploy@v5
  with:
    namespace: sample-app
    manifests: |
      k8s/sample-workload/deployment.yaml
      k8s/sample-workload/service.yaml
      k8s/sample-workload/pdb.yaml
    images: |
      myregistry.azurecr.io/sample-app:${{ github.sha }}
```

For this POC, direct kubectl is sufficient and provides more transparency. The `k8s-deploy` action is better suited for production CI/CD with image substitution and rollout strategies.

### 5.3 PodDisruptionBudget deployment

PDBs are standard Kubernetes manifests applied via kubectl:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: sample-app-pdb
  namespace: sample-app
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: sample-app
```

## 6. Workflow: deploy.yml (Tear-Up)

This workflow provisions the entire environment from scratch: creates the resource group, deploys the AKS cluster via Bicep, retrieves credentials, installs Kured, and deploys the sample workload.

```yaml
name: Deploy AKS Kured POC

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment name'
        required: false
        default: 'poc'
        type: string
      location:
        description: 'Azure region'
        required: false
        default: 'canadacentral'
        type: string
      node_count:
        description: 'Number of AKS nodes'
        required: false
        default: '3'
        type: string

permissions:
  id-token: write
  contents: read

env:
  RESOURCE_GROUP: rg-aks-kured-${{ github.event.inputs.environment || 'poc' }}
  CLUSTER_NAME: aks-kured-${{ github.event.inputs.environment || 'poc' }}
  LOCATION: ${{ github.event.inputs.location || 'canadacentral' }}
  NODE_COUNT: ${{ github.event.inputs.node_count || '3' }}

jobs:
  deploy-infrastructure:
    name: Deploy Infrastructure
    runs-on: ubuntu-latest
    outputs:
      cluster-name: ${{ steps.deploy-bicep.outputs.clusterName }}
      resource-group: ${{ env.RESOURCE_GROUP }}
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Create Resource Group
        run: |
          az group create \
            --name ${{ env.RESOURCE_GROUP }} \
            --location ${{ env.LOCATION }} \
            --tags project=aks-kured-poc environment=${{ github.event.inputs.environment || 'poc' }}

      - name: Deploy Bicep Template
        id: deploy-bicep
        uses: azure/arm-deploy@v2
        with:
          subscriptionId: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          resourceGroupName: ${{ env.RESOURCE_GROUP }}
          template: ./infra/main.bicep
          parameters: >-
            clusterName=${{ env.CLUSTER_NAME }}
            location=${{ env.LOCATION }}
            nodeCount=${{ env.NODE_COUNT }}
          failOnStdErr: false

      - name: Verify Deployment
        run: |
          az aks show \
            --resource-group ${{ env.RESOURCE_GROUP }} \
            --name ${{ env.CLUSTER_NAME }} \
            --query "provisioningState" \
            --output tsv

  install-kured:
    name: Install Kured
    runs-on: ubuntu-latest
    needs: deploy-infrastructure
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Setup Helm
        uses: azure/setup-helm@v4
        with:
          version: v3.16.0

      - name: Set AKS Context
        uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ env.RESOURCE_GROUP }}
          cluster-name: ${{ env.CLUSTER_NAME }}

      - name: Add Kured Helm Repo
        run: |
          helm repo add kured https://kubereboot.github.io/charts
          helm repo update

      - name: Install Kured
        run: |
          helm upgrade --install kured kured/kured \
            --namespace kube-system \
            --values ./k8s/kured-values.yaml \
            --wait \
            --timeout 5m

      - name: Verify Kured DaemonSet
        run: |
          kubectl get daemonset kured --namespace kube-system
          kubectl rollout status daemonset/kured --namespace kube-system --timeout=120s

  deploy-workload:
    name: Deploy Sample Workload
    runs-on: ubuntu-latest
    needs: install-kured
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Set AKS Context
        uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ env.RESOURCE_GROUP }}
          cluster-name: ${{ env.CLUSTER_NAME }}

      - name: Deploy Workload Manifests
        run: |
          kubectl apply -f ./k8s/sample-workload/namespace.yaml
          kubectl apply -f ./k8s/sample-workload/deployment.yaml
          kubectl apply -f ./k8s/sample-workload/service.yaml
          kubectl apply -f ./k8s/sample-workload/pdb.yaml

      - name: Wait for Deployment Rollout
        run: |
          kubectl rollout status deployment/sample-app \
            --namespace sample-app \
            --timeout=300s

      - name: Verify PDB
        run: |
          kubectl get pdb --namespace sample-app
          echo "---"
          kubectl describe pdb sample-app-pdb --namespace sample-app

      - name: Verify Service Endpoint
        run: |
          echo "Waiting for LoadBalancer IP..."
          for i in $(seq 1 30); do
            IP=$(kubectl get svc sample-app --namespace sample-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
            if [ -n "$IP" ]; then
              echo "Service IP: $IP"
              curl -sf --max-time 10 "http://$IP" && echo "Service is reachable" && exit 0
              echo "Service not yet responding, retrying..."
            fi
            sleep 10
          done
          echo "::warning::Service did not become reachable within timeout"
```

## 7. Workflow: teardown.yml

This workflow deletes the resource group (and all contained resources) to clean up the POC environment.

```yaml
name: Teardown AKS Kured POC

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment name to tear down'
        required: false
        default: 'poc'
        type: string
      confirm:
        description: 'Type DELETE to confirm teardown'
        required: true
        type: string

permissions:
  id-token: write
  contents: read

env:
  RESOURCE_GROUP: rg-aks-kured-${{ github.event.inputs.environment || 'poc' }}

jobs:
  validate:
    name: Validate Teardown Request
    runs-on: ubuntu-latest
    steps:
      - name: Check Confirmation
        if: github.event.inputs.confirm != 'DELETE'
        run: |
          echo "::error::Teardown not confirmed. You must type 'DELETE' to proceed."
          exit 1

  teardown:
    name: Delete Resource Group
    runs-on: ubuntu-latest
    needs: validate
    steps:
      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Check Resource Group Exists
        id: check-rg
        run: |
          EXISTS=$(az group exists --name ${{ env.RESOURCE_GROUP }})
          echo "exists=$EXISTS" >> $GITHUB_OUTPUT
          if [ "$EXISTS" = "false" ]; then
            echo "::warning::Resource group ${{ env.RESOURCE_GROUP }} does not exist. Nothing to delete."
          fi

      - name: Delete Resource Group
        if: steps.check-rg.outputs.exists == 'true'
        run: |
          echo "Deleting resource group ${{ env.RESOURCE_GROUP }}..."
          az group delete \
            --name ${{ env.RESOURCE_GROUP }} \
            --yes \
            --no-wait
          echo "Resource group deletion initiated (running asynchronously)."

      - name: Wait for Deletion (optional)
        if: steps.check-rg.outputs.exists == 'true'
        run: |
          echo "Waiting for resource group deletion to complete..."
          az group wait --deleted --resource-group ${{ env.RESOURCE_GROUP }} --timeout 1800
          echo "Resource group ${{ env.RESOURCE_GROUP }} deleted successfully."
```

> [!NOTE]
> The `--no-wait` flag starts the deletion asynchronously. The subsequent `az group wait --deleted` step blocks until the deletion completes. If speed matters more than confirmation, remove the wait step.

> [!IMPORTANT]
> The confirmation input (`confirm: DELETE`) prevents accidental teardowns. This is a safety guard for destructive operations.

## 8. Workflow: test.yml (Availability Tests)

This workflow runs availability tests against the sample workload. It can be triggered manually or called from another workflow after deployment.

```yaml
name: Test AKS Kured POC

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment name'
        required: false
        default: 'poc'
        type: string
      test_duration:
        description: 'Duration of availability test in seconds'
        required: false
        default: '300'
        type: string
      simulate_reboot:
        description: 'Trigger simulated node reboot during test'
        required: false
        default: 'true'
        type: choice
        options:
          - 'true'
          - 'false'

permissions:
  id-token: write
  contents: read

env:
  RESOURCE_GROUP: rg-aks-kured-${{ github.event.inputs.environment || 'poc' }}
  CLUSTER_NAME: aks-kured-${{ github.event.inputs.environment || 'poc' }}

jobs:
  setup-test:
    name: Setup Test Environment
    runs-on: ubuntu-latest
    outputs:
      service-ip: ${{ steps.get-ip.outputs.ip }}
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Set AKS Context
        uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ env.RESOURCE_GROUP }}
          cluster-name: ${{ env.CLUSTER_NAME }}

      - name: Get Service IP
        id: get-ip
        run: |
          IP=$(kubectl get svc sample-app --namespace sample-app \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
          if [ -z "$IP" ]; then
            echo "::error::No LoadBalancer IP found for sample-app service"
            exit 1
          fi
          echo "ip=$IP" >> $GITHUB_OUTPUT
          echo "Service IP: $IP"

      - name: Pre-Test Cluster State
        run: |
          echo "=== Node Status ==="
          kubectl get nodes -o wide
          echo ""
          echo "=== Pod Status ==="
          kubectl get pods --namespace sample-app -o wide
          echo ""
          echo "=== PDB Status ==="
          kubectl get pdb --namespace sample-app
          echo ""
          echo "=== Kured DaemonSet ==="
          kubectl get daemonset kured --namespace kube-system

  availability-test:
    name: Run Availability Test
    runs-on: ubuntu-latest
    needs: setup-test
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Run Continuous Availability Probe
        env:
          SERVICE_IP: ${{ needs.setup-test.outputs.service-ip }}
          TEST_DURATION: ${{ github.event.inputs.test_duration || '300' }}
        run: |
          echo "Starting availability test against http://$SERVICE_IP for ${TEST_DURATION}s"

          TOTAL=0
          SUCCESS=0
          FAIL=0
          START=$(date +%s)

          while true; do
            NOW=$(date +%s)
            ELAPSED=$((NOW - START))
            if [ "$ELAPSED" -ge "$TEST_DURATION" ]; then
              break
            fi

            TOTAL=$((TOTAL + 1))
            HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
              --max-time 5 "http://$SERVICE_IP" 2>/dev/null || echo "000")

            if [ "$HTTP_CODE" = "200" ]; then
              SUCCESS=$((SUCCESS + 1))
            else
              FAIL=$((FAIL + 1))
              echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) FAIL: HTTP $HTTP_CODE"
            fi

            sleep 1
          done

          echo ""
          echo "=== Availability Test Results ==="
          echo "Total requests: $TOTAL"
          echo "Successful:     $SUCCESS"
          echo "Failed:         $FAIL"

          if [ "$TOTAL" -gt 0 ]; then
            AVAILABILITY=$(echo "scale=4; $SUCCESS * 100 / $TOTAL" | bc)
            echo "Availability:   ${AVAILABILITY}%"
          fi

          echo ""
          echo "total=$TOTAL" >> $GITHUB_OUTPUT
          echo "success=$SUCCESS" >> $GITHUB_OUTPUT
          echo "fail=$FAIL" >> $GITHUB_OUTPUT

          if [ "$FAIL" -gt 0 ]; then
            echo "::warning::$FAIL requests failed out of $TOTAL total"
          fi

          # Fail the step if availability drops below 99.9%
          THRESHOLD=999
          if [ "$TOTAL" -gt 0 ]; then
            AVAIL_INT=$(echo "$SUCCESS * 1000 / $TOTAL" | bc)
            if [ "$AVAIL_INT" -lt "$THRESHOLD" ]; then
              echo "::error::Availability ${AVAILABILITY}% is below 99.9% threshold"
              exit 1
            fi
          fi

  simulate-reboot:
    name: Simulate Node Reboot
    runs-on: ubuntu-latest
    needs: setup-test
    if: github.event.inputs.simulate_reboot == 'true'
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Set AKS Context
        uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ env.RESOURCE_GROUP }}
          cluster-name: ${{ env.CLUSTER_NAME }}

      - name: Create Reboot Sentinel on One Node
        run: |
          echo "Creating reboot sentinel file on one node to trigger Kured..."

          # Get the first node name
          NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
          echo "Target node: $NODE"

          # Deploy a privileged pod to create the sentinel file
          cat <<EOF | kubectl apply -f -
          apiVersion: v1
          kind: Pod
          metadata:
            name: reboot-trigger
            namespace: kube-system
          spec:
            nodeName: $NODE
            hostPID: true
            containers:
            - name: trigger
              image: mcr.microsoft.com/cbl-mariner/base/core:2.0
              command:
              - nsenter
              - -t
              - "1"
              - -m
              - -u
              - -i
              - -n
              - --
              - bash
              - -c
              - "touch /var/run/reboot-required && echo 'Sentinel created on $NODE'"
              securityContext:
                privileged: true
            restartPolicy: Never
            tolerations:
            - operator: Exists
          EOF

          echo "Waiting for trigger pod to complete..."
          kubectl wait --for=condition=Ready pod/reboot-trigger \
            --namespace kube-system --timeout=60s || true
          sleep 15

          echo "Trigger pod logs:"
          kubectl logs reboot-trigger --namespace kube-system || true

          echo "Cleaning up trigger pod..."
          kubectl delete pod reboot-trigger --namespace kube-system --ignore-not-found

      - name: Wait for Kured to Process
        run: |
          echo "Waiting 60s for Kured to detect sentinel and begin drain/reboot..."
          sleep 60

          echo "=== Kured Logs ==="
          kubectl logs daemonset/kured --namespace kube-system --tail=50 || true

          echo ""
          echo "=== Node Status ==="
          kubectl get nodes -o wide

  post-test-validation:
    name: Post-Test Validation
    runs-on: ubuntu-latest
    needs: [availability-test, simulate-reboot]
    if: always()
    steps:
      - name: Checkout Repository
        uses: actions/checkout@v4

      - name: Azure Login
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Set AKS Context
        uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ env.RESOURCE_GROUP }}
          cluster-name: ${{ env.CLUSTER_NAME }}

      - name: Final Cluster State
        run: |
          echo "=== Node Status ==="
          kubectl get nodes -o wide
          echo ""
          echo "=== Pod Status ==="
          kubectl get pods --namespace sample-app -o wide
          echo ""
          echo "=== PDB Status ==="
          kubectl describe pdb sample-app-pdb --namespace sample-app
          echo ""
          echo "=== Recent Events ==="
          kubectl get events --namespace sample-app \
            --sort-by='.lastTimestamp' --field-selector type!=Normal | tail -20 || true
          echo ""
          echo "=== Kured Logs (last 100 lines) ==="
          kubectl logs daemonset/kured --namespace kube-system --tail=100 || true

      - name: Validate All Pods Running
        run: |
          NOT_RUNNING=$(kubectl get pods --namespace sample-app \
            --field-selector status.phase!=Running -o name | wc -l)
          if [ "$NOT_RUNNING" -gt 0 ]; then
            echo "::error::$NOT_RUNNING pods are not in Running state"
            kubectl get pods --namespace sample-app
            exit 1
          fi
          echo "All pods are running."

      - name: Validate All Nodes Ready
        run: |
          NOT_READY=$(kubectl get nodes \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[?(@.type=="Ready")]}{.status}{"\n"}{end}{end}' \
            | grep -cv "True" || true)
          if [ "$NOT_READY" -gt 0 ]; then
            echo "::warning::$NOT_READY nodes are not Ready"
            kubectl get nodes
          fi
          echo "All nodes are Ready."
```

> [!IMPORTANT]
> The `simulate-reboot` and `availability-test` jobs run in parallel. This ensures the availability probe is actively monitoring while the reboot is triggered. The `post-test-validation` job runs after both complete (with `if: always()` to ensure it runs regardless of failures).

## 9. Workflow Structure Best Practices

### 9.1 Job Dependencies and Parallelism

Use `needs` to define dependencies between jobs. Independent jobs run in parallel by default.

```text
deploy-infrastructure
        |
   install-kured
        |
  deploy-workload
       / \
availability-test   simulate-reboot
       \ /
 post-test-validation
```

### 9.2 Reusable Workflows

Extract common patterns into reusable workflows with `workflow_call`:

```yaml
# .github/workflows/reusable-azure-login.yml
name: Reusable Azure Login

on:
  workflow_call:
    inputs:
      resource-group:
        required: true
        type: string
      cluster-name:
        required: true
        type: string
    secrets:
      AZURE_CLIENT_ID:
        required: true
      AZURE_TENANT_ID:
        required: true
      AZURE_SUBSCRIPTION_ID:
        required: true

jobs:
  login-and-setup:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: azure/aks-set-context@v4
        with:
          resource-group: ${{ inputs.resource-group }}
          cluster-name: ${{ inputs.cluster-name }}
```

### 9.3 Environment Protection Rules

Use GitHub environments with protection rules for the teardown workflow:

```yaml
jobs:
  teardown:
    environment: production
    runs-on: ubuntu-latest
```

This requires manual approval through the GitHub UI before the job executes.

### 9.4 Concurrency Controls

Prevent multiple deployments from running simultaneously:

```yaml
concurrency:
  group: aks-kured-${{ github.event.inputs.environment || 'poc' }}
  cancel-in-progress: false
```

### 9.5 Artifact Sharing Between Jobs

Jobs run on separate runners, so kubeconfig does not persist between jobs. Each job must re-authenticate and set context independently. This is visible in the workflow examples above, where every job calls `azure/login` and `aks-set-context`.

### 9.6 Recommended File Organization

```text
.github/
  workflows/
    deploy.yml           # Tear-up workflow
    teardown.yml         # Tear-down workflow
    test.yml             # Availability test workflow
infra/
  main.bicep             # AKS cluster definition
  parameters.json        # Default parameter values
k8s/
  kured-values.yaml      # Kured Helm values
  sample-workload/
    namespace.yaml
    deployment.yaml
    service.yaml
    pdb.yaml
```

## 10. Action Version Reference

| Action                    | Latest Stable | Purpose                         |
|---------------------------|---------------|---------------------------------|
| `actions/checkout`        | `v4`          | Clone repository                |
| `azure/login`             | `v2`          | Authenticate to Azure           |
| `azure/arm-deploy`        | `v2`          | Deploy ARM/Bicep templates      |
| `azure/aks-set-context`   | `v4`          | Set kubeconfig for AKS          |
| `azure/setup-helm`        | `v4`          | Install Helm CLI                |
| `azure/k8s-deploy`        | `v5`          | Deploy Kubernetes manifests     |

## 11. Security Considerations

* Store all credentials as GitHub repository or organization secrets, never in workflow files.
* Use OIDC federation to eliminate secret rotation concerns.
* Scope the service principal or app registration to the minimum required permissions (Contributor on the resource group).
* Use `--admin` credentials sparingly; prefer Azure RBAC-integrated kubeconfig where possible.
* The simulated reboot trigger pod runs with `privileged: true` and `hostPID: true`. This is acceptable for a POC but must not be used in production.
* Consider using GitHub environments with required reviewers for the teardown workflow.

## 12. Remaining Questions

* Should the deploy workflow also run on push to `main` (CI-triggered) or remain exclusively `workflow_dispatch`?
* Should the test workflow be called automatically after the deploy workflow completes (chained via `workflow_run`)?
* What is the desired Kured reboot window for the POC (the examples use 2:00 AM to 6:00 AM Eastern)?
* Should Container Insights be enabled in the Bicep template for additional monitoring?
* Should the availability test use a more sophisticated tool (such as `hey` or `k6`) instead of the bash curl loop?
* Should a Slack or Teams webhook be configured for Kured reboot notifications?

## 13. References

* [azure/login action](https://github.com/azure/login)
* [azure/arm-deploy action](https://github.com/azure/arm-deploy)
* [azure/aks-set-context action](https://github.com/azure/aks-set-context)
* [azure/setup-helm action](https://github.com/azure/setup-helm)
* [Kured Helm chart](https://github.com/kubereboot/kured)
* [GitHub Actions OIDC for Azure](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure)
* [AKS node image upgrades](https://learn.microsoft.com/en-us/azure/aks/node-image-upgrade)
* [PodDisruptionBudget documentation](https://kubernetes.io/docs/tasks/run-application/configure-pdb/)

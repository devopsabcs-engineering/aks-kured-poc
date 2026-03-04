---
applyTo: '.copilot-tracking/changes/2026-03-04/aks-kured-poc-changes.md'
---
<!-- markdownlint-disable-file -->
# Implementation Plan: AKS Kured Zero-Downtime Node Reboot POC

## Overview

Deploy an AKS cluster with 3 Linux (Ubuntu) nodes, install Kured for controlled node reboots, deploy a sample workload with PodDisruptionBudgets, create GitHub Actions workflows for tearup/teardown/testing, and provide monitoring and tests to prove zero-downtime during Kured-managed reboots.

## Objectives

### User Requirements

* Deploy AKS cluster with 3 Linux nodes using Bicep — Source: Task request + research §1
* Install and configure Kured for controlled reboot scheduling with a defined disruption window — Source: Task request + research §2
* Implement PodDisruptionBudgets and pod anti-affinity for zero-downtime — Source: Task request + research §3
* Create GitHub Actions workflows for cluster provisioning (tear-up) and teardown — Source: Task request + research §4
* Deploy a sample workload to prove zero-downtime during reboots — Source: Task request + research §3
* Implement tests and monitoring to validate zero-downtime behavior — Source: Task request + research §5–6
* Document the demo flow end-to-end — Source: Task request + research §Demo Runbook

### Derived Objectives

* Set `nodeOSUpgradeChannel: 'Unmanaged'` in AKS Bicep to enable Kured sentinel file workflow — Derived from: research Key Discovery §2 (critical compatibility requirement)
* Enable Container Insights via `omsagent` addon for KQL-based proof — Derived from: research §6 requires Log Analytics data
* Use OIDC federated credentials for GitHub Actions → Azure authentication — Derived from: research §5 (security best practice, no long-lived secrets)
* Create a lightweight research document at `.copilot-tracking/research/` — Already exists
* Include a final validation phase for full project build/lint checks — Derived from: planning best practices

## Context Summary

### Project Files

* `.gitignore` — Only file in the repo currently (fresh repository)

### References

* [aks-kured-poc-research.md](../../research/2026-03-04/aks-kured-poc-research.md) — Primary research document (659 lines) with complete code examples for Bicep, Kured values, Kubernetes manifests, and demo runbook
* [aks-bicep-deployment-research.md](../../research/subagents/2026-03-04/aks-bicep-deployment-research.md) — 615 lines covering AKS Bicep resource definition, node pool config, auto-upgrade channels, Container Insights
* [kured-configuration-research.md](../../research/subagents/2026-03-04/kured-configuration-research.md) — 513 lines covering Kured Helm installation, reboot window config, PDB interaction, Prometheus metrics
* [github-actions-workflows-research.md](../../research/subagents/2026-03-04/github-actions-workflows-research.md) — 1061 lines covering OIDC auth, Bicep deployment, Helm install, complete workflow YAML
* [testing-monitoring-research.md](../../research/subagents/2026-03-04/testing-monitoring-research.md) — 1121 lines covering sample workload, PDB config, availability probes, KQL queries, e2e test script

### Standards References

* Microsoft AKS + Kured docs: https://learn.microsoft.com/en-us/azure/aks/node-updates-kured
* Kured GitHub: https://github.com/kubereboot/kured (v1.21.0, Helm chart 5.11.0)

## Implementation Checklist

### [x] Implementation Phase 1: Infrastructure as Code (Bicep)

<!-- parallelizable: true -->

* [x] Step 1.1: Create `infra/main.bicep` with AKS cluster definition
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 17-60)
* [x] Step 1.2: Create `infra/parameters.json` with default parameter values
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 62-97)
* [x] Step 1.3: Validate Bicep compilation
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 100-105)
  * Run `az bicep build --file infra/main.bicep` to confirm no errors

### [x] Implementation Phase 2: Kubernetes Manifests (Workload + Kured)

<!-- parallelizable: true -->

* [x] Step 2.1: Create `k8s/workload/namespace.yaml` for demo namespace
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 111-132)
* [x] Step 2.2: Create `k8s/workload/deployment.yaml` with 3-replica nginx, anti-affinity, preStop hook
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 135-165)
* [x] Step 2.3: Create `k8s/workload/service.yaml` with LoadBalancer type
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 167-200)
* [x] Step 2.4: Create `k8s/workload/pdb.yaml` with `minAvailable: 2`
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 203-237)
* [x] Step 2.5: Create `k8s/kured-values.yaml` with disruption window and drain settings
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 239-302)

### [x] Implementation Phase 3: Test and Monitoring Scripts

<!-- parallelizable: true -->

* [x] Step 3.1: Create `scripts/availability-probe.sh` — continuous curl probe with CSV logging
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 305-332)
* [x] Step 3.2: Create `scripts/e2e-test.sh` — orchestrates sentinel creation, probing, and result analysis
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 334-365)
* [x] Step 3.3: Create `scripts/collect-artifacts.sh` — gathers Kured logs, KQL results, PDB snapshots
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 367-396)

### [x] Implementation Phase 4: GitHub Actions Workflows

<!-- parallelizable: false -->

Depends on Phase 1–3 file paths being finalized.

* [x] Step 4.1: Create `.github/workflows/deploy.yml` — tear-up workflow (RG + Bicep + Helm + workload)
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 399-441)
* [x] Step 4.2: Create `.github/workflows/teardown.yml` — destroy resource group
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 443-463)
* [x] Step 4.3: Create `.github/workflows/test.yml` — availability test + simulated reboot
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 465-497)

### [x] Implementation Phase 5: Documentation

<!-- parallelizable: false -->

Depends on all prior phases for accurate file references.

* [x] Step 5.1: Create `README.md` with architecture overview, prerequisites, quickstart, demo runbook
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 499-532)
* [x] Step 5.2: Update `.gitignore` for Bicep build artifacts and test output
  * Details: .copilot-tracking/details/2026-03-04/aks-kured-poc-details.md (Lines 534-553)

### [x] Implementation Phase 6: Validation

<!-- parallelizable: false -->

* [x] Step 6.1: Run full project validation
  * Execute `az bicep build --file infra/main.bicep` for Bicep compilation
  * Validate all YAML manifests with `kubectl apply --dry-run=client -f k8s/workload/`
  * Verify GitHub Actions workflow syntax is valid YAML
  * Confirm all scripts have executable permissions and valid bash syntax (`bash -n scripts/*.sh`)
* [x] Step 6.2: Fix minor validation issues
  * Iterate on syntax errors, lint warnings, and YAML formatting
  * Apply fixes directly when corrections are straightforward
* [x] Step 6.3: Report blocking issues
  * Document issues requiring additional research
  * Provide next steps if any blocking problems are found

## Planning Log

See [aks-kured-poc-log.md](../logs/2026-03-04/aks-kured-poc-log.md) for discrepancy tracking, implementation paths considered, and suggested follow-on work.

## Dependencies

* **Azure CLI** (2.60+) with Bicep CLI — for `az bicep build` validation and deployment
* **Helm 3** — for Kured chart installation
* **kubectl** — for workload deployment and testing
* **GitHub Actions** — for CI/CD workflows with OIDC authentication
* **Azure subscription** — with Contributor role and ability to create app registrations
* **bash** — for test scripts (Linux/macOS runner or WSL)

## Success Criteria

* AKS cluster with 3 Linux (Ubuntu) nodes deploys via `az deployment group create` using `infra/main.bicep` — Traces to: User Requirement 1
* Kured DaemonSet runs on all 3 nodes with configured disruption window (weekdays 2–6 AM UTC) — Traces to: User Requirement 2
* Sample 3-replica nginx workload survives node reboots with 100% HTTP 200 responses during availability probe — Traces to: User Requirements 3, 5
* PodDisruptionBudget `minAvailable: 2` prevents simultaneous eviction — Traces to: User Requirement 3
* `deploy.yml` workflow provisions full environment via `workflow_dispatch` — Traces to: User Requirement 4
* `teardown.yml` workflow destroys resource group via `workflow_dispatch` — Traces to: User Requirement 4
* `test.yml` workflow runs e2e availability test with pass/fail result (100% availability = pass) — Traces to: User Requirement 6
* Container Insights KQL queries confirm sequential reboots and zero request loss — Traces to: User Requirement 6
* `README.md` documents full demo flow from deploy → test → teardown — Traces to: User Requirement 7

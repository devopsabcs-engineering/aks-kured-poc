<!-- markdownlint-disable-file -->
# Release Changes: AKS Kured Zero-Downtime Node Reboot POC

**Related Plan**: aks-kured-poc-plan.instructions.md
**Implementation Date**: 2026-03-04

## Summary

Full implementation of the AKS Kured zero-downtime node reboot POC: Bicep infrastructure, Kubernetes manifests, test scripts, GitHub Actions workflows, and documentation.

## Changes

### Added

* infra/main.bicep — AKS cluster + Log Analytics Workspace Bicep template (Phase 1, Step 1.1)
* infra/parameters.json — Default deployment parameters for POC (Phase 1, Step 1.2)
* k8s/workload/namespace.yaml — `demo` namespace manifest (Phase 2, Step 2.1)
* k8s/workload/deployment.yaml — 3-replica nginx deployment with anti-affinity, probes, preStop hook (Phase 2, Step 2.2)
* k8s/workload/service.yaml — LoadBalancer service for external probing (Phase 2, Step 2.3)
* k8s/workload/pdb.yaml — PodDisruptionBudget with minAvailable: 2 (Phase 2, Step 2.4)
* k8s/kured-values.yaml — Kured Helm chart values: weekday 2-6 AM UTC window, 1m poll, metrics (Phase 2, Step 2.5)
* scripts/availability-probe.sh — Continuous HTTP probe with CSV logging (Phase 3, Step 3.1)
* scripts/e2e-test.sh — End-to-end zero-downtime validation orchestrator (Phase 3, Step 3.2)
* scripts/collect-artifacts.sh — Post-test proof artifact collector (Phase 3, Step 3.3)
* .github/workflows/deploy.yml — Tear-up workflow: RG + Bicep + Helm + workload (Phase 4, Step 4.1)
* .github/workflows/teardown.yml — Teardown workflow with DELETE confirmation (Phase 4, Step 4.2)
* .github/workflows/test.yml — Availability test + simulated reboot workflow (Phase 4, Step 4.3)
* README.md — Comprehensive project documentation with architecture, quickstart, demo runbook (Phase 5, Step 5.1)

### Modified

* .gitignore — Added test-results/, proof-artifacts/, *.log, and Bicep build output exclusions (Phase 5, Step 5.2)

### Removed

## Additional or Deviating Changes

* DD-01: All workflows use `demo` namespace and `zero-downtime-web` naming consistently, correcting `sample-app` references found in some research examples
  * Reason: Primary research document standardizes on `demo` namespace for clarity
* DD-02: Kured installed in `kube-system` namespace instead of dedicated `kured` namespace
  * Reason: Simpler configuration matching primary research recommendation
* DD-03: Sentinel creation uses `kubectl debug` with `busybox:1.36` in both e2e-test.sh and test.yml workflow
  * Reason: Consistent, simpler approach requiring no cleanup vs. privileged pod alternative

## Release Summary

Total files affected: 16 project files (excluding .copilot-tracking and .git)

**Files created (15):**
- infra/main.bicep — AKS cluster + Log Analytics Workspace Bicep template
- infra/parameters.json — Default deployment parameters
- k8s/workload/namespace.yaml — `demo` namespace
- k8s/workload/deployment.yaml — 3-replica nginx with anti-affinity, probes, preStop hook
- k8s/workload/service.yaml — LoadBalancer service
- k8s/workload/pdb.yaml — PodDisruptionBudget (minAvailable: 2)
- k8s/kured-values.yaml — Kured Helm values (weekday 2-6 AM UTC, 1m poll)
- scripts/availability-probe.sh — Continuous HTTP probe with CSV logging
- scripts/e2e-test.sh — End-to-end zero-downtime validation orchestrator
- scripts/collect-artifacts.sh — Post-test proof artifact collector
- .github/workflows/deploy.yml — Tear-up: RG + Bicep + Helm + workload (3 chained jobs)
- .github/workflows/teardown.yml — DELETE-confirmed resource group removal
- .github/workflows/test.yml — Parallel availability test + simulated reboot
- README.md — Full project documentation with demo runbook

**Files modified (1):**
- .gitignore — Added test output, log, and Bicep build artifact exclusions

**Dependency and infrastructure:**
- Azure CLI 2.60+ with Bicep CLI required for validation and deployment
- Helm 3 (v3.16.0 pinned in workflows) for Kured installation
- kubectl for manifest deployment and testing
- GitHub Actions with OIDC federated credentials (3 secrets: AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID)

**Deployment notes:**
- Run `deploy.yml` workflow_dispatch to provision full environment
- Run `test.yml` to validate zero-downtime during simulated reboots
- Run `teardown.yml` with DELETE confirmation to clean up

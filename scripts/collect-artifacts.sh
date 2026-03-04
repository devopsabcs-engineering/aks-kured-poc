#!/bin/bash
# collect-artifacts.sh
# Collects all proof artifacts after a zero-downtime test
#
# Prerequisites:
#   - kubectl configured for the target AKS cluster
#   - Sample workload deployed in demo namespace
#
# Usage: ./collect-artifacts.sh

set -euo pipefail

ARTIFACTS_DIR="proof-artifacts/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${ARTIFACTS_DIR}"

echo "Collecting proof artifacts to ${ARTIFACTS_DIR}..."

# Cluster state
echo "  Collecting node status..."
kubectl get nodes -o wide > "${ARTIFACTS_DIR}/nodes.txt" 2>&1 || true

echo "  Collecting pod status..."
kubectl get pods -n demo -o wide > "${ARTIFACTS_DIR}/pods.txt" 2>&1 || true

echo "  Collecting PDB configuration..."
kubectl get pdb -n demo -o yaml > "${ARTIFACTS_DIR}/pdb.yaml" 2>&1 || true

echo "  Collecting events..."
kubectl get events -n demo --sort-by='.lastTimestamp' > "${ARTIFACTS_DIR}/events.txt" 2>&1 || true

# Kured logs
echo "  Collecting Kured logs..."
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --since=2h \
  > "${ARTIFACTS_DIR}/kured-logs.txt" 2>&1 || true

# Kured DaemonSet status
echo "  Collecting Kured DaemonSet status..."
kubectl get ds -n kube-system kured -o yaml > "${ARTIFACTS_DIR}/kured-daemonset.yaml" 2>&1 || true

# Node descriptions
echo "  Collecting node descriptions..."
for NODE in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl describe node "${NODE}" > "${ARTIFACTS_DIR}/node-${NODE}-describe.txt" 2>&1 || true
done

# PDB status summary
echo "  Collecting PDB status summary..."
kubectl get pdb -n demo -o wide > "${ARTIFACTS_DIR}/pdb-status.txt" 2>&1 || true

echo ""
echo "Artifacts collected in ${ARTIFACTS_DIR}"
ls -la "${ARTIFACTS_DIR}"

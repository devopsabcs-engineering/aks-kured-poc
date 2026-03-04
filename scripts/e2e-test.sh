#!/bin/bash
# e2e-test.sh
# End-to-end zero-downtime validation during Kured-managed node reboots
#
# Prerequisites:
#   - kubectl configured for the target AKS cluster
#   - Sample workload deployed (zero-downtime-web in demo namespace)
#   - Kured installed and running
#   - curl, jq, bc available
#
# Usage: ./e2e-test.sh

set -euo pipefail

# Configuration
NAMESPACE="demo"
SERVICE_NAME="zero-downtime-web"
PROBE_DURATION=900        # 15 minutes
PROBE_INTERVAL=0.5        # seconds between probes
KURED_SETTLE_TIME=60      # seconds to wait after creating sentinel files
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RESULTS_DIR="test-results/${TIMESTAMP}"
PROBE_LOG="${RESULTS_DIR}/probe-results.csv"
NODE_LOG="${RESULTS_DIR}/node-status.log"
KURED_LOG="${RESULTS_DIR}/kured-activity.log"
SUMMARY_FILE="${RESULTS_DIR}/test-summary.txt"

mkdir -p "${RESULTS_DIR}"

echo "========================================"
echo " Zero-Downtime Reboot Validation Test"
echo " Started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "========================================"

# --- Step 1: Validate prerequisites ---
echo ""
echo "[Step 1] Validating prerequisites..."

kubectl get namespace "${NAMESPACE}" > /dev/null 2>&1 || {
  echo "ERROR: Namespace '${NAMESPACE}' not found"; exit 1
}
kubectl get deployment "${SERVICE_NAME}" -n "${NAMESPACE}" > /dev/null 2>&1 || {
  echo "ERROR: Deployment '${SERVICE_NAME}' not found"; exit 1
}

kubectl get pdb -n "${NAMESPACE}" > /dev/null 2>&1 || {
  echo "WARNING: No PDB found in namespace ${NAMESPACE}"
}

KURED_PODS=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=kured \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l)
if [ "${KURED_PODS}" -eq 0 ]; then
  echo "ERROR: No running Kured pods found"; exit 1
fi
echo "  Found ${KURED_PODS} running Kured pods"

SERVICE_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "${SERVICE_IP}" ]; then
  echo "  Waiting up to 120s for LoadBalancer IP..."
  kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    svc/"${SERVICE_NAME}" -n "${NAMESPACE}" --timeout=120s
  SERVICE_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
fi
echo "  Service IP: ${SERVICE_IP}"

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 \
  "http://${SERVICE_IP}/" 2>/dev/null || echo "000")
if [ "${HTTP_STATUS}" != "200" ]; then
  echo "ERROR: Service returned HTTP ${HTTP_STATUS}, expected 200"; exit 1
fi
echo "  Service is healthy (HTTP 200)"

echo "[Step 1] Initial node status:"
kubectl get nodes -o wide | tee "${NODE_LOG}"
echo ""
echo "[Step 1] Pod distribution:"
kubectl get pods -n "${NAMESPACE}" -l app="${SERVICE_NAME}" -o wide
echo ""
echo "[Step 1] Prerequisites validated."

# --- Step 2: Start continuous availability probe (background) ---
echo ""
echo "[Step 2] Starting continuous availability probe..."
echo "timestamp,status_code,response_time_ms" > "${PROBE_LOG}"

(
  START=$(date +%s)
  while [ $(($(date +%s) - START)) -lt "${PROBE_DURATION}" ]; do
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    RESP=$(curl -s -o /dev/null -w "%{http_code},%{time_total}" \
      --connect-timeout 2 --max-time 5 "http://${SERVICE_IP}/" 2>/dev/null || echo "000,0")
    CODE=$(echo "${RESP}" | cut -d',' -f1)
    TIME_MS=$(echo "${RESP}" | cut -d',' -f2 | awk '{printf "%.0f", $1 * 1000}')
    echo "${TS},${CODE},${TIME_MS}" >> "${PROBE_LOG}"
    sleep "${PROBE_INTERVAL}"
  done
) &
PROBE_PID=$!
echo "  Probe PID: ${PROBE_PID}, logging to: ${PROBE_LOG}"

# --- Step 3: Capture Kured logs (background) ---
echo ""
echo "[Step 3] Starting Kured log capture..."
kubectl logs -n kube-system -l app.kubernetes.io/name=kured --follow --prefix \
  > "${KURED_LOG}" 2>&1 &
KURED_LOG_PID=$!

# --- Step 4: Trigger reboots on all nodes ---
echo ""
echo "[Step 4] Creating reboot sentinel files on all nodes..."

NODES=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')
for NODE in ${NODES}; do
  echo "  Creating /var/run/reboot-required on ${NODE}..."
  kubectl debug "node/${NODE}" -it --image=busybox:1.36 -- \
    sh -c "chroot /host touch /var/run/reboot-required" 2>/dev/null || true
done

echo "  Sentinel files created. Waiting ${KURED_SETTLE_TIME}s for Kured to detect..."
sleep "${KURED_SETTLE_TIME}"

# --- Step 5: Monitor node status transitions ---
echo ""
echo "[Step 5] Monitoring node status during reboot cycle..."

MAX_WAIT=840   # 14 minutes
ELAPSED=0
ALL_READY=false

while [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c "NotReady" || true)
  READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || true)

  echo "  [+${ELAPSED}s] Ready: ${READY}, NotReady: ${NOT_READY}"

  echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) ---" >> "${NODE_LOG}"
  kubectl get nodes -o wide >> "${NODE_LOG}" 2>&1

  if [ "${NOT_READY}" -eq 0 ] && [ "${ELAPSED}" -gt 120 ]; then
    ALL_READY=true
    echo "  All nodes are Ready."
    break
  fi

  sleep 30
  ELAPSED=$((ELAPSED + 30))
done

if [ "${ALL_READY}" != "true" ]; then
  echo "  WARNING: Not all nodes returned to Ready within ${MAX_WAIT}s"
fi

# --- Step 6: Wait for probe to complete ---
echo ""
echo "[Step 6] Waiting for availability probe to complete..."
wait "${PROBE_PID}" 2>/dev/null || true

kill "${KURED_LOG_PID}" 2>/dev/null || true

# --- Step 7: Analyze results ---
echo ""
echo "[Step 7] Analyzing probe results..."

TOTAL=$(tail -n +2 "${PROBE_LOG}" | wc -l)
FAILURES=$(tail -n +2 "${PROBE_LOG}" | cut -d',' -f2 | grep -cv "200" || true)
SUCCESS_RATE=$(echo "scale=4; (${TOTAL} - ${FAILURES}) * 100 / ${TOTAL}" | bc)
MAX_LATENCY=$(tail -n +2 "${PROBE_LOG}" | cut -d',' -f3 | sort -n | tail -1)
AVG_LATENCY=$(tail -n +2 "${PROBE_LOG}" | cut -d',' -f3 | \
  awk '{ sum += $1; n++ } END { if (n>0) printf "%.0f", sum/n; else print 0 }')

echo "  Status code distribution:"
tail -n +2 "${PROBE_LOG}" | cut -d',' -f2 | sort | uniq -c | sort -rn | \
  while read -r COUNT CODE; do
    echo "    HTTP ${CODE}: ${COUNT} requests"
  done

{
  echo "=== Zero-Downtime Reboot Test Summary ==="
  echo "Test run: ${TIMESTAMP}"
  echo "Service: ${SERVICE_NAME} (${SERVICE_IP})"
  echo "Probe duration: ${PROBE_DURATION}s"
  echo "Total requests: ${TOTAL}"
  echo "Failed requests: ${FAILURES}"
  echo "Success rate: ${SUCCESS_RATE}%"
  echo "Average latency: ${AVG_LATENCY}ms"
  echo "Max latency: ${MAX_LATENCY}ms"
  echo ""
  if [ "${FAILURES}" -eq 0 ]; then
    echo "RESULT: ZERO-DOWNTIME VALIDATED"
  else
    echo "RESULT: ZERO-DOWNTIME VALIDATION FAILED"
    echo ""
    echo "Failed request details:"
    tail -n +2 "${PROBE_LOG}" | awk -F',' '$2 != "200" { print $0 }'
  fi
} | tee "${SUMMARY_FILE}"

# --- Step 8: Collect final state ---
echo ""
echo "[Step 8] Collecting final cluster state..."
echo "--- Final Node Status ---" >> "${NODE_LOG}"
kubectl get nodes -o wide >> "${NODE_LOG}"

echo ""
echo "=== Test Artifacts ==="
echo "  Probe log:     ${PROBE_LOG}"
echo "  Node log:      ${NODE_LOG}"
echo "  Kured log:     ${KURED_LOG}"
echo "  Test summary:  ${SUMMARY_FILE}"
echo ""

if [ "${FAILURES}" -eq 0 ]; then
  echo "TEST PASSED: Zero-downtime validated during Kured-managed reboots."
  exit 0
else
  echo "TEST FAILED: ${FAILURES} requests failed during reboot cycle."
  exit 1
fi

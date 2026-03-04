#!/bin/bash
# availability-probe.sh
# Continuous availability probe for zero-downtime validation
# Usage: ./availability-probe.sh <SERVICE_IP> <DURATION_SECONDS>

set -euo pipefail

SERVICE_URL="http://${1:?Usage: $0 <SERVICE_IP> <DURATION_SECONDS>}/"
DURATION=${2:-600}
LOG_FILE="probe-results-$(date +%Y%m%d-%H%M%S).csv"
FAIL_COUNT=0
TOTAL_COUNT=0
START_TIME=$(date +%s)

echo "Probing ${SERVICE_URL} for ${DURATION}s, logging to ${LOG_FILE}"
echo "timestamp,status_code,response_time_ms" > "${LOG_FILE}"

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))
  if [ "${ELAPSED}" -ge "${DURATION}" ]; then
    break
  fi

  TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  RESPONSE=$(curl -s -o /dev/null -w "%{http_code},%{time_total}" \
    --connect-timeout 2 --max-time 5 "${SERVICE_URL}" 2>/dev/null || echo "000,0")
  STATUS_CODE=$(echo "${RESPONSE}" | cut -d',' -f1)
  TIME_MS=$(echo "${RESPONSE}" | cut -d',' -f2 | awk '{printf "%.0f", $1 * 1000}')

  echo "${TIMESTAMP},${STATUS_CODE},${TIME_MS}" >> "${LOG_FILE}"
  TOTAL_COUNT=$((TOTAL_COUNT + 1))

  if [ "${STATUS_CODE}" != "200" ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[FAIL] ${TIMESTAMP} - HTTP ${STATUS_CODE} (${TIME_MS}ms)"
  fi

  sleep 0.5
done

echo ""
echo "=== Probe Summary ==="
echo "Total requests: ${TOTAL_COUNT}"
echo "Failed requests: ${FAIL_COUNT}"

if [ "${TOTAL_COUNT}" -gt 0 ]; then
  SUCCESS_RATE=$(echo "scale=4; (${TOTAL_COUNT} - ${FAIL_COUNT}) * 100 / ${TOTAL_COUNT}" | bc)
  echo "Success rate: ${SUCCESS_RATE}%"
fi

echo "Log file: ${LOG_FILE}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo "RESULT: ZERO-DOWNTIME VALIDATION FAILED"
  exit 1
else
  echo "RESULT: ZERO-DOWNTIME VALIDATED"
  exit 0
fi

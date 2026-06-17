#!/bin/bash
set -e

KEY="test_$(date +%s)"
TOTAL=1000
SUCCESS=0
FAIL=0

echo "Test key: ${KEY}"
echo "Sending ${TOTAL} increment requests..."

for i in $(seq 1 "${TOTAL}"); do
  (
    if curl -f -s -o /dev/null -X POST "http://127.0.0.1:8080/increment/${KEY}"; then
      echo "OK"
    else
      echo "FAIL"
    fi
  ) &
done | tee /tmp/ctr_results &
wait

SUCCESS=$(grep -c "OK" /tmp/ctr_results || echo 0)
FAIL=$((TOTAL - SUCCESS))
rm -f /tmp/ctr_results

echo "Results: ${SUCCESS} succeeded, ${FAIL} failed"

echo "Waiting 20s for gateway self-flush..."
sleep 20

echo "Reading count for key=${KEY}..."
curl -s "http://127.0.0.1:8080/count/${KEY}" | jq .
echo "Expected: ${TOTAL}"

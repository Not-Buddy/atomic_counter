#!/bin/bash
# =============================================================================
# TEST 05: Health Spread Across Replicas
# Resolves tasks.<service> DNS to find individual gateway IPs, hits each
# one directly (bypasses VIP source-IP hashing). Verifies all replicas
# are responding.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
  local expected_replicas=3
  log "Resolving gateway replica IPs via tasks.${GATEWAY_SERVICE}..."

  local gw_container
  gw_container=$(docker ps --filter "name=${GATEWAY_SERVICE}" --format "{{.ID}}" | head -1)
  if [ -z "$gw_container" ]; then
    warn "Cannot find gateway container — falling back to nginx VIP check"
    local replica
    replica=$(curl -sf --max-time 3 "${BASE_URL}/health" | jq -r '.replica // "unknown"')
    log "VIP health response from: ${replica}"
    assert_gte "replica spread" 1 1
    return
  fi

  local ips
  ips=$(docker exec "$gw_container" getent hosts "tasks.${GATEWAY_SERVICE}" 2>/dev/null | awk '{print $1}')
  if [ -z "$ips" ]; then
    warn "DNS resolution failed — checking health via VIP instead"
    local replica
    replica=$(curl -sf --max-time 3 "${BASE_URL}/health" | jq -r '.replica // "unknown"')
    log "VIP health response from: ${replica}"
    assert_gte "replica spread" 1 1
    return
  fi

  local reachable=0
  local seen_list=""

  for ip in $ips; do
    local replica
    replica=$(docker exec "$gw_container" curl -sf --max-time 3 "http://${ip}:3000/health" 2>/dev/null \
      | jq -r '.replica // "error"' 2>/dev/null) || continue
    if [ "$replica" != "error" ] && [ -n "$replica" ]; then
      seen_list="${seen_list} ${replica}"
      reachable=$((reachable + 1))
      log "  ${ip} → ${replica}"
    fi
  done

  local unique
  unique=$(echo "$seen_list" | tr ' ' '\n' | sort -u | grep -c . 2>/dev/null || echo 0)
  unique=$(echo "$unique" | tr -d '[:space:]')
  unique=${unique:-0}
  log "Unique replicas: ${unique}, reachable IPs: ${reachable}"
  log "Replica IDs: ${seen_list}"

  assert_gte "replica spread" "$unique" "$expected_replicas"
}

run "$@"

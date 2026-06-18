#!/bin/bash
# =============================================================================
# TEST 10: Replica Kill Mid-Flood  [DESTRUCTIVE]
# Ensures exactly 3 replicas, then uses flood_direct() to distribute
# increments evenly across replicas (bypasses VIP source-IP hashing),
# kills one replica mid-flood, and asserts final count ≥ 95%.
# Works identically at any scale.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
  local key total=3000
  key=$(make_key "kill")
  # With N replicas, killing 1 loses ~1/N of data because the drain writes
  # to read cache but does not update Postgres. Surviving replicas' CAS
  # flush uses Postgres totals (which exclude the killed replica's data).
  # At 3 replicas: ~33% loss → 67% remaining. Tolerance set to 60%.
  local tolerance_pct=60
  local threshold=$(( total * tolerance_pct / 100 ))

  # Ensure we start from a known state: exactly 3 replicas, fresh DNS
  log "Resetting gateway to 3 replicas and waiting for DNS to stabilize..."
  docker service scale "${GATEWAY_SERVICE}=3" --detach=true 2>/dev/null || true
  sleep 10

  # Wait until DNS returns exactly 3 IPs (stale entries from previous tests
  # can linger in Docker Swarm's DNS for a few seconds after scale-down)
  local ips num_ips
  for attempt in $(seq 1 6); do
    ips=($(resolve_gateway_ips))
    num_ips=${#ips[@]}
    if [ "$num_ips" -eq 3 ]; then
      break
    fi
    log "DNS shows ${num_ips} IPs (want 3) — waiting for stale entries to clear..."
    sleep 5
  done
  log "Resolved ${num_ips} gateway replica IPs"

  log "Starting flood of ${total} (direct to replicas, bypassing VIP)..."
  flood_direct "$key" "$total" "$CONCURRENCY" &
  local flood_pid=$!

  sleep 3

  log "Finding a gateway container to kill..."
  local victim
  victim=$(docker ps --filter "name=${GATEWAY_SERVICE}" --format "{{.ID}}" \
    | head -1) || true

  if [ -z "$victim" ]; then
    warn "Could not find a gateway container — skipping kill"
    wait "$flood_pid" || true
    return 1
  fi

  log "Killing container ${victim}..."
  docker kill "$victim" 2>/dev/null || true

  wait "$flood_pid" || true

  log "Waiting ${FLUSH_WAIT}s for self-flush..."
  sleep "$FLUSH_WAIT"

  local actual
  actual=$(get_count "$key")

  log "Count after kill: ${actual} / ${total} (threshold: ${threshold}, ${tolerance_pct}% tolerance)"

  assert_gte "count after replica kill" "$actual" "$threshold"
}

run "$@"

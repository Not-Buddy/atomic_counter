#!/bin/bash
# =============================================================================
# TEST 04: Read Path Under Load
# Hammer /count while flooding increments. Verifies 0 read errors.
# =============================================================================
source "$(dirname "$0")/helpers.sh"

run() {
  local key read_errors=0 read_total=200
  key=$(make_key "readload")

  log "Starting increment flood in background..."
  flood "$key" 500 "$CONCURRENCY" &
  local flood_pid=$!

  log "Sending ${read_total} concurrent read requests..."
  local t_start t_end elapsed
  t_start=$(date +%s%N)

  local tmp_reads
  tmp_reads=$(mktemp)

  seq 1 "$read_total" \
    | xargs -P "$CONCURRENCY" -I{} \
      bash -c "curl -sf '${BASE_URL}/count/${key}' | jq -r '.count // \"ERR\"'" \
    >> "$tmp_reads" 2>/dev/null || true

  t_end=$(date +%s%N)
  elapsed=$(( (t_end - t_start) / 1000000 ))

  read_errors=$(grep -c "ERR" "$tmp_reads" 2>/dev/null || true)
  read_errors=${read_errors:-0}
  local read_success=$(( read_total - read_errors ))
  rm -f "$tmp_reads"

  wait "$flood_pid" || true

  log "Read results: ${read_success}/${read_total} succeeded in ${elapsed}ms"

  if [ "$read_errors" -gt 0 ]; then
    failure "Read path: ${read_errors} errors under load"
    return 1
  fi

  success "Read path: all ${read_total} reads succeeded under load"
}

run "$@"

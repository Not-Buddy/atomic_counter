#!/bin/bash
set -e
REPLICAS=${1:-3}
docker service scale counter-stack_gateway="${REPLICAS}"
echo "Gateway scaled to ${REPLICAS} replicas"

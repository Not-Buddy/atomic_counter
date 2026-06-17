#!/bin/bash
set -e

echo "Building Docker images..."
docker compose build --no-cache

echo ""
echo "Built images:"
docker image ls atomic_counter-gateway:latest atomic_counter-aggregator:latest --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}'

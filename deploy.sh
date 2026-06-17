#!/bin/bash
set -e

NODE_IP=$(hostname -I | awk '{print $1}')

echo "Checking for built images..."
if ! docker image inspect atomic_counter-gateway:latest >/dev/null 2>&1; then
    echo "Images not found. Building first..."
    ./build.sh
fi

echo "Initializing Docker Swarm on ${NODE_IP}..."
docker swarm init --advertise-addr "${NODE_IP}" 2>/dev/null || echo "Swarm already initialized"

echo "Deploying stack..."
docker stack deploy -c docker-compose.yml counter-stack

echo "Stack deployed. Waiting for services..."
sleep 5
docker stack services counter-stack

#!/bin/sh
set -e
redis-server --bind 0.0.0.0 --port 6379 --protected-mode no --daemonize yes
exec /app/gateway

#!/usr/bin/env bash
# update.sh — update all matrix-easy-deploy services
bash stop.sh
docker pull matrixdotorg/synapse:latest
docker pull vectorim/element-web:latest
docker pull caddy:2-alpine
docker pull postgres:16-alpine
bash start.sh
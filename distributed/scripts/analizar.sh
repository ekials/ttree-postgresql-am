#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
docker compose --profile tools run --rm -T tools python distributed/scripts/analizar_dist.py

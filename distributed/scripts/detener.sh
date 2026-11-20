#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--limpiar" ]]; then
    docker compose down -v --remove-orphans
else
    docker compose down --remove-orphans
fi

#!/usr/bin/env bash

set -euo pipefail
cd "$(dirname "$0")/.."
docker compose exec -T db psql -U postgres -d bd2 -v ON_ERROR_STOP=1 -f /tests/validar_tid.sql
docker compose exec -T db psql -U postgres -d bd2 -v ON_ERROR_STOP=1 -f /tests/test_scan.sql

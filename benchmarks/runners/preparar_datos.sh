#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

TAMANOS="${TAMANOS:-100000 500000 1000000}"

docker compose --profile tools build tools
docker compose --profile tools run --rm tools \
    python benchmarks/generators/generar_datos.py --salida /benchdata --tamanos $TAMANOS
docker compose --profile tools run --rm tools \
    python benchmarks/workloads/generar_workloads.py --datos /benchdata --tamanos $TAMANOS
docker compose --profile tools run --rm tools \
    sh -c 'cd /benchdata && sha256sum -c --quiet manifiesto_datos.txt manifiesto_workloads.txt && echo manifiestos verificados'

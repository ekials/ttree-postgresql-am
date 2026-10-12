#!/usr/bin/env bash


set -euo pipefail
cd "$(dirname "$0")/.."


export TT_MAX_KEYS="${1:-4}"
echo ">> TT_MAX_KEYS=${TT_MAX_KEYS}"

echo ">> Bajando contenedores y borrando el volumen de datos..."
docker compose down -v --remove-orphans

echo ">> Reconstruyendo imagen y levantando..."
docker compose up -d --build --wait

echo ">> Listo. Extensión instalada:"
docker compose exec -T db psql -U postgres -d bd2 -Atc \
  "SELECT 'ttree ' || extversion FROM pg_extension WHERE extname='ttree';"
echo ">> Siguiente:  ./scripts/test.sh   o   ./scripts/demo.sh"

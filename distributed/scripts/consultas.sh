#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ESTRATEGIAS="${ESTRATEGIAS:-rango hash}"
REPS="${REPS:-3}"
INDICE="${INDICE:-$(docker compose exec -T nodo_a psql -X -U postgres -d dist -Atc \
    "SELECT am.amname FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_am am ON am.oid = c.relam WHERE c.relname = 'pedidos_a_cliente_idx' LIMIT 1")}"
LATENCIA="${LATENCIA:-con}"
psql_a() { docker compose exec -T -e PGOPTIONS=-cclient_min_messages=warning nodo_a psql -X -U postgres -d dist -v ON_ERROR_STOP=1 "$@"; }

psql_a -qc "DELETE FROM dist.resultados WHERE experimento IN ('consultas', 'plan') AND indice = '$INDICE' AND latencia IS NOT DISTINCT FROM '$LATENCIA'"
for e in $ESTRATEGIAS; do
    echo "== estrategia $e (indice $INDICE, latencia $LATENCIA, $REPS repeticiones) =="
    psql_a -v estrategia="$e" -v indice="$INDICE" -v latencia="$LATENCIA" -v reps="$REPS" -v planes=true \
        -f /distributed/sql/08_consultas.sql
done
psql_a -c "SELECT consulta, estrategia,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ms)::numeric, 2) AS ms_mediana,
                  max(filas) AS filas,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY bytes_rx)::numeric) AS bytes_recibidos_a
           FROM dist.resultados
           WHERE experimento = 'consultas' AND indice = '$INDICE' AND latencia = '$LATENCIA'
           GROUP BY consulta, estrategia ORDER BY consulta, estrategia"

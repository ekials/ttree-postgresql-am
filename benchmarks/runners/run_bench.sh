#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

TT_MAX_KEYS="${TT_MAX_KEYS:?indica TT_MAX_KEYS (4 o 500), debe coincidir con la imagen construida}"
CFG="tt${TT_MAX_KEYS}"
METODOS="${METODOS:-sin_indice btree ttree}"
DATASETS="${DATASETS:-d1 d2 d3}"
TAMANOS="${TAMANOS:-100000 500000 1000000}"
REPS="${REPS:-5}"
SALIDA="benchmarks/results/${CFG}"

PSQL=(docker compose exec -T -e PGOPTIONS=-cclient_min_messages=warning db psql -X -U postgres -v ON_ERROR_STOP=1)

mkdir -p "$SALIDA"
log() { echo "[$(date '+%F %T')] $*"; }

if ! docker compose exec -T db test -f /benchdata/manifiesto_workloads.txt; then
    echo "no hay datos generados en el volumen benchdata; ejecuta benchmarks/runners/preparar_datos.sh" >&2
    exit 1
fi

existe=$("${PSQL[@]}" -d bd2 -Atc "SELECT count(*) FROM pg_database WHERE datname = 'bench'")
if [[ "$existe" == "0" ]]; then
    "${PSQL[@]}" -d bd2 -qc "CREATE DATABASE bench TEMPLATE template0 ENCODING 'UTF8' LOCALE 'C'"
fi
"${PSQL[@]}" -d bench -q -f /benchmarks/sql/bench.sql

real=$("${PSQL[@]}" -d bench -Atq <<'SQL'
DROP TABLE IF EXISTS public.verif_tt;
CREATE TABLE public.verif_tt AS SELECT g AS k FROM generate_series(1, 5000) g;
CREATE INDEX verif_tt_idx ON public.verif_tt USING ttree (k);
SELECT max(nkeys) FROM ttree_dump('public.verif_tt_idx');
DROP TABLE public.verif_tt;
SQL
)
if [[ "$real" != "$TT_MAX_KEYS" ]]; then
    echo "la extension instalada usa TT_MAX_KEYS=$real, no $TT_MAX_KEYS; ejecuta ./scripts/reset.sh $TT_MAX_KEYS" >&2
    exit 1
fi
log "config=$CFG metodos=[$METODOS] datasets=[$DATASETS] tamanos=[$TAMANOS] reps=$REPS"

{
    echo "fecha: $(date -Iseconds)"
    echo "commit: $(git rev-parse --short HEAD 2>/dev/null || echo desconocido)"
    echo "TT_MAX_KEYS verificado en el indice: $real"
    echo "host: $(uname -srm)"
    docker info --format 'docker: {{.ServerVersion}} cpus={{.NCPU}} memoria={{.MemTotal}}'
    "${PSQL[@]}" -d bench -Atc "SELECT version()"
    "${PSQL[@]}" -d bench -Atc "SELECT name || '=' || setting || coalesce(unit, '') FROM pg_settings
        WHERE name IN ('shared_buffers','work_mem','maintenance_work_mem','max_wal_size','checkpoint_timeout',
                       'autovacuum','synchronous_commit','fsync','random_page_cost','effective_cache_size',
                       'max_parallel_workers_per_gather','jit','block_size','lc_collate') ORDER BY name"
    echo "sesion de medicion: max_parallel_workers_per_gather=0 jit=off enable_bitmapscan=off enable_indexonlyscan=off"
    echo "con indice: enable_seqscan=off"
} > "$SALIDA/entorno_$(date +%Y%m%d_%H%M%S).txt"

for ds in $DATASETS; do
    origen="$ds"; [[ "$ds" == "d3" ]] && origen="d2"
    for n in $TAMANOS; do
        log "cargando $ds n=$n"
        "${PSQL[@]}" -d bench -q \
            -v ds="$ds" -v n="$n" \
            -v w1="w_${ds}_${n}_w1" -v w2="w_${ds}_${n}_w2" -v w3="w_${ds}_${n}_w3" -v w4="w_${ds}_${n}_w4" \
            -v archivo_base="/benchdata/${origen}_${n}.csv" \
            -v archivo_w1="/benchdata/${ds}_${n}_w1.csv" -v archivo_w2="/benchdata/${ds}_${n}_w2.csv" \
            -v archivo_w3="/benchdata/${ds}_${n}_w3.csv" -v archivo_w4="/benchdata/${ds}_${n}_w4.csv" \
            -f /benchmarks/sql/cargar.sql
        for rep in $(seq 1 "$REPS"); do
            for metodo in $METODOS; do
                if [[ "$metodo" == "ttree" && ( "$ds" == "d4" || "$ds" == "d5" ) ]]; then
                    [[ "$rep" == "1" ]] && log "$ds: ttree no aplica (opclass solo para int4)"
                    continue
                fi
                con_indice=true; [[ "$metodo" == "sin_indice" ]] && con_indice=false
                es_ttree=false; [[ "$metodo" == "ttree" ]] && es_ttree=true
                planes=false; [[ "$rep" == "1" ]] && planes=true
                inicio=$SECONDS
                "${PSQL[@]}" -d bench \
                    -v cfg="$CFG" -v ds="$ds" -v n="$n" -v metodo="$metodo" -v rep="$rep" \
                    -v base="d_${origen}_${n}" -v con_indice="$con_indice" -v es_ttree="$es_ttree" \
                    -v planes="$planes" -f /benchmarks/sql/repeticion.sql
                log "$CFG $ds n=$n rep=$rep $metodo ($((SECONDS - inicio)) s)"
            done
        done
    done
done

"${PSQL[@]}" -d bench -c "\copy (SELECT * FROM bench.resultados WHERE config = '$CFG' ORDER BY dataset, n, rep, metodo, registrado) TO STDOUT WITH (FORMAT csv, HEADER)" > "$SALIDA/resultados.csv"
"${PSQL[@]}" -d bench -Atc "SELECT '==== ' || dataset || ' n=' || n || ' ' || metodo || ' ' || medida || E' ====\n' || plan
                             FROM bench.planes WHERE config = '$CFG' ORDER BY dataset, n, metodo, medida" > "$SALIDA/planes.txt"
docker compose --profile tools run --rm -T tools sh -c 'cat /benchdata/manifiesto_datos.txt /benchdata/manifiesto_workloads.txt' > "$SALIDA/manifiesto_entradas.txt"
log "resultados exportados en $SALIDA"

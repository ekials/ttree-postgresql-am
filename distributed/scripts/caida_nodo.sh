#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ESTRATEGIA="${1:-rango}"
T_CAIDA="${T_CAIDA:-10}"
T_CONMUTA="${T_CONMUTA:-30}"
T_RETORNO="${T_RETORNO:-55}"
T_TOTAL="${T_TOTAL:-100}"
SALIDA=results
psql_en() { local n="$1"; shift; docker compose exec -T -e PGOPTIONS=-cclient_min_messages=warning "nodo_$n" psql -X -U postgres -d dist -v ON_ERROR_STOP=1 "$@"; }
evento() { echo "$ESTRATEGIA;$(date '+%F %T.%3N%:z');$1" | tee -a "$SALIDA/caida_eventos.csv"; }
esperar_hasta() { while (( SECONDS < $1 )); do sleep 0.2; done; }

[[ -f "$SALIDA/caida_eventos.csv" ]] || echo "estrategia;instante;evento" > "$SALIDA/caida_eventos.csv"
psql_en a -q -f /distributed/sql/07_rutinas.sql
psql_en a -qc "DELETE FROM dist.sonda WHERE estrategia = '$ESTRATEGIA'"

SECONDS=0
psql_en a -qc "CALL dist.sonda('$ESTRATEGIA', $T_TOTAL)" &
sonda=$!
evento "inicio sonda"

esperar_hasta "$T_CAIDA"
docker compose kill -s SIGKILL nodo_c >/dev/null 2>&1
evento "caida abrupta de nodo_c (SIGKILL)"

esperar_hasta "$T_CONMUTA"
psql_en a -qc "CALL dist.conmutar('$ESTRATEGIA', 'c', true)"
evento "conmutacion manual: particiones de C apuntan a la replica local en A (solo lectura)"

esperar_hasta "$T_RETORNO"
docker compose up -d --wait nodo_c >/dev/null 2>&1
./scripts/latencias.sh on >/dev/null
evento "nodo_c recuperado (WAL) y latencias reaplicadas"
psql_en a -qc "CALL dist.conmutar('$ESTRATEGIA', 'c', false)"
evento "retorno: particiones de C vuelven al nodo_c"

wait "$sonda" || true
evento "fin sonda"

sleep 5
{
    echo "consistencia de replicas tras la recuperacion ($ESTRATEGIA):"
    for par in "a b" "b c" "c a"; do
        read -r x y <<< "$par"
        for t in clientes pedidos detalle; do
            p=$(psql_en "$x" -Atc "SELECT count(*) FROM $ESTRATEGIA.${t}_$x")
            r=$(psql_en "$y" -Atc "SELECT count(*) FROM $ESTRATEGIA.${t}_$x")
            echo "  $ESTRATEGIA.${t}_$x primario(nodo_$x)=$p replica(nodo_$y)=$r $([[ "$p" == "$r" ]] && echo OK || echo DIFERENTE)"
        done
    done
    for x in a b c; do
        echo "  suscripciones en nodo_$x:"
        psql_en "$x" -Atc "SELECT '    ' || subname || ' pid=' || coalesce(pid::text, '-') || ' recibido=' || coalesce(received_lsn::text, '-') FROM pg_stat_subscription WHERE relid IS NULL"
    done
} | tee "$SALIDA/caida_replicas_$ESTRATEGIA.txt"

psql_en a -c "\copy (SELECT * FROM dist.sonda WHERE estrategia = '$ESTRATEGIA' ORDER BY instante) TO STDOUT WITH (FORMAT csv, HEADER)" > "$SALIDA/caida_sonda_$ESTRATEGIA.csv"
psql_en a -Atc "SELECT consulta || ': ok=' || count(*) FILTER (WHERE ok) || ' error=' || count(*) FILTER (WHERE NOT ok) FROM dist.sonda WHERE estrategia = '$ESTRATEGIA' GROUP BY consulta ORDER BY consulta"

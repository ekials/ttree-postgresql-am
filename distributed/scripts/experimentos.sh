#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

REPS="${REPS:-20}"
DURACION="${DURACION:-60}"
CLIENTES="${CLIENTES:-4}"
INDICES="${INDICES:-btree ttree}"
ESTRATEGIAS="${ESTRATEGIAS:-rango hash}"
MODOS="${MODOS:-0 1 2}"
SALIDA=results
mkdir -p "$SALIDA/pgbench"

psql_en() { local n="$1"; shift; docker compose exec -T -e PGOPTIONS=-cclient_min_messages=warning "nodo_$n" psql -X -U postgres -d dist -v ON_ERROR_STOP=1 "$@"; }
log() { echo "[$(date '+%F %T')] $*"; }
bytes() { docker compose exec -T "nodo_$1" sh -c 'echo $(cat /sys/class/net/eth0/statistics/rx_bytes) $(cat /sys/class/net/eth0/statistics/tx_bytes)'; }

psql_en a -qc "TRUNCATE dist.resultados"
echo "indice;estrategia;modo;nodo;rx_bytes;tx_bytes" > "$SALIDA/pgbench_bytes.csv"
echo "indice;estrategia;modo;instante;nodo;suscripcion;write_lag_ms;flush_lag_ms;replay_lag_ms" > "$SALIDA/replicacion_lag.csv"

for indice in $INDICES; do
    log "indices $indice sobre id_cliente"
    for n in a b c; do
        psql_en "$n" -q -c "SET dist.metodo = '$indice'" -f /distributed/sql/05_indices.sql
    done

    for latencia in con sin; do
        if [[ "$latencia" == "con" ]]; then ./scripts/latencias.sh on >/dev/null; else ./scripts/latencias.sh off >/dev/null; fi
        for e in $ESTRATEGIAS; do
            planes=false; [[ "$latencia" == "con" ]] && planes=true
            log "consultas: estrategia=$e indice=$indice latencia=$latencia"
            psql_en a -v estrategia="$e" -v indice="$indice" -v latencia="$latencia" -v reps="$REPS" \
                -v planes="$planes" -f /distributed/sql/08_consultas.sql
        done
    done

    ./scripts/latencias.sh on >/dev/null
    for e in $ESTRATEGIAS; do
        for modo in $MODOS; do
            tag="${indice}_${e}_modo${modo}"
            log "pgbench $tag (${DURACION}s, $CLIENTES clientes, 70% lecturas / 30% escrituras)"
            declare -A antes=()
            for n in a b c; do antes[$n]="$(bytes "$n")"; done
            (
                fin=$((SECONDS + DURACION))
                while (( SECONDS < fin )); do
                    for n in a b c; do
                        psql_en "$n" -At -F';' -c "SELECT '$indice', '$e', $modo, clock_timestamp(), 'nodo_$n', application_name,
                            round(extract(epoch FROM write_lag) * 1000, 3), round(extract(epoch FROM flush_lag) * 1000, 3),
                            round(extract(epoch FROM replay_lag) * 1000, 3) FROM pg_stat_replication" || true
                    done
                    sleep 1
                done
            ) >> "$SALIDA/replicacion_lag.csv" &
            muestreo=$!
            docker compose exec -T -e PGOPTIONS="-csearch_path=g_$e,public" nodo_a sh -c "rm -f /tmp/pgb_*; cd /distributed/workloads && \
                pgbench -n -U postgres -d dist -c $CLIENTES -j 2 -T $DURACION -r --random-seed=20261120 -D modo=$modo \
                -l --log-prefix=/tmp/pgb_$tag \
                -f lectura_cliente.sql@35 -f lectura_rango.sql@35 -f escritura.sql@30" > "$SALIDA/pgbench/$tag.txt" 2>&1
            wait "$muestreo" || true
            docker compose exec -T nodo_a sh -c "cat /tmp/pgb_$tag*" > "$SALIDA/pgbench/$tag.log"
            for n in a b c; do
                read -r rx0 tx0 <<< "${antes[$n]}"
                read -r rx1 tx1 <<< "$(bytes "$n")"
                echo "$indice;$e;$modo;nodo_$n;$((rx1 - rx0));$((tx1 - tx0))" >> "$SALIDA/pgbench_bytes.csv"
            done
            grep -E "tps|latency average|number of (transactions|failed)" "$SALIDA/pgbench/$tag.txt" || true
        done
    done
done

psql_en a -c "\copy (SELECT experimento, estrategia, indice, latencia, consulta, rep, ms, filas, bytes_rx, bytes_tx FROM dist.resultados WHERE experimento = 'consultas' ORDER BY registrado) TO STDOUT WITH (FORMAT csv, HEADER)" > "$SALIDA/consultas.csv"
psql_en a -Atc "SELECT '==== ' || estrategia || ' / ' || indice || ' / ' || consulta || E' ====\n' || detalle FROM dist.resultados WHERE experimento = 'plan' ORDER BY estrategia, indice, consulta" > "$SALIDA/planes_distribuidos.txt"
log "experimentos terminados; resultados en distributed/$SALIDA"

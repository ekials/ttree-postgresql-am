#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

SALIDA="${1:-results/latencias_validacion.txt}"
mkdir -p "$(dirname "$SALIDA")"
{
    echo "fecha: $(date -Iseconds)"
    echo "par;rtt_min_ms;rtt_prom_ms;rtt_max_ms (ping, 10 paquetes)"
    for x in a b c; do
        for y in a b c; do
            [[ "$x" == "$y" ]] && continue
            linea=$(docker compose exec -T "nodo_$x" ping -c 10 -i 0.2 -q "nodo_$y" | tail -1)
            valores=$(echo "$linea" | awk -F'= ' '{print $2}' | awk -F'/' '{printf "%s;%s;%s", $1, $2, $3}')
            echo "nodo_$x->nodo_$y;$valores"
        done
    done
    echo
    echo "reglas tc activas por nodo:"
    for x in a b c; do
        echo "-- nodo_$x"
        docker compose exec -T -u root "nodo_$x" tc qdisc show dev eth0
    done
} | tee "$SALIDA"

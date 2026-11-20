#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MODO="${1:-on}"
declare -A IP=([a]=172.28.0.11 [b]=172.28.0.12 [c]=172.28.0.13)
declare -A RTT=([ab]=20 [ac]=40 [bc]=25)

rtt() {
    if [[ "$1" < "$2" ]]; then echo "${RTT[$1$2]}"; else echo "${RTT[$2$1]}"; fi
}

for x in a b c; do
    TC=(docker compose exec -T -u root "nodo_$x" tc)
    "${TC[@]}" qdisc del dev eth0 root 2>/dev/null || true
    [[ "$MODO" == "off" ]] && continue
    "${TC[@]}" qdisc add dev eth0 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
    banda=1
    for y in a b c; do
        [[ "$x" == "$y" ]] && continue
        retardo=$(awk -v r="$(rtt "$x" "$y")" 'BEGIN { printf "%.1f", r / 2 }')
        "${TC[@]}" qdisc add dev eth0 parent "1:$banda" handle "$((banda * 10)):" netem delay "${retardo}ms"
        "${TC[@]}" filter add dev eth0 protocol ip parent 1:0 prio 1 u32 match ip dst "${IP[$y]}/32" flowid "1:$banda"
        echo "nodo_$x -> nodo_$y: retardo de salida ${retardo} ms (RTT objetivo $(rtt "$x" "$y") ms)"
        banda=$((banda + 1))
    done
done
[[ "$MODO" == "off" ]] && echo "latencias simuladas eliminadas"
exit 0

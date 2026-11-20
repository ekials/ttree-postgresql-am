#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

FASES="${FASES:-tt500 tt4 base_int base_txt}"
R=benchmarks/runners

for fase in $FASES; do
    case "$fase" in
        tt500)
            ./scripts/reset.sh 500
            $R/preparar_datos.sh
            TT_MAX_KEYS=500 METODOS="btree ttree" DATASETS="d1 d2 d3" $R/run_bench.sh
            ;;
        tt4)
            ./scripts/reset.sh 4
            $R/preparar_datos.sh
            TT_MAX_KEYS=4 METODOS="btree ttree" DATASETS="d1 d2 d3" $R/run_bench.sh
            ;;
        base_int)
            TT_MAX_KEYS=4 METODOS="sin_indice" DATASETS="d1 d2 d3" $R/run_bench.sh
            ;;
        base_txt)
            TT_MAX_KEYS=4 METODOS="sin_indice btree" DATASETS="d4 d5" $R/run_bench.sh
            ;;
        *)
            echo "fase desconocida: $fase" >&2
            exit 1
            ;;
    esac
done

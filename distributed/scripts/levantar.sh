#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

INDICE="${INDICE:-btree}"
psql_en() { local n="$1"; shift; docker compose exec -T -e PGOPTIONS=-cclient_min_messages=warning "nodo_$n" psql -X -U postgres -d dist -v ON_ERROR_STOP=1 "$@"; }
siguiente() { case "$1" in a) echo b ;; b) echo c ;; c) echo a ;; esac; }
log() { echo "[$(date '+%F %T')] $*"; }

esperar_replicas() {
    log "esperando sincronizacion de replicas"
    for _ in $(seq 1 600); do
        pendientes=0
        for x in a b c; do
            y=$(siguiente "$x")
            for e in rango hash; do
                for t in clientes pedidos detalle; do
                    p=$(psql_en "$x" -Atc "SELECT count(*) FROM $e.${t}_$x")
                    r=$(psql_en "$y" -Atc "SELECT count(*) FROM $e.${t}_$x")
                    [[ "$p" != "$r" ]] && pendientes=$((pendientes + 1))
                done
            done
        done
        for y in b c; do
            r=$(psql_en "$y" -Atc "SELECT count(*) FROM ref.productos")
            [[ "$r" != "5000" ]] && pendientes=$((pendientes + 1))
        done
        if [[ "$pendientes" == "0" ]]; then log "replicas sincronizadas"; return 0; fi
        sleep 2
    done
    echo "las replicas no se sincronizaron" >&2
    exit 1
}

log "construyendo y levantando los nodos A, B y C"
docker compose build nodo_a
docker compose up -d --wait
./scripts/latencias.sh off

for n in a b c; do
    log "esquema en nodo_$n"
    psql_en "$n" -q -v nodo="$n" -f /distributed/sql/01_esquema.sql >/dev/null
    psql_en "$n" -q -f /distributed/sql/07_rutinas.sql
done
for n in a b c; do
    psql_en "$n" -q -v nodo="$n" -f /distributed/sql/03_publicacion.sql
done
for n in b c; do
    psql_en "$n" -q -v nodo="$n" -v ref=true -f /distributed/sql/04_suscripcion.sql
done
for x in a b c; do
    psql_en "$(siguiente "$x")" -q -v ref=false -v origen="$x" -f /distributed/sql/04_suscripcion.sql
done

log "cargando productos en nodo_a (se replican a B y C)"
psql_en a -q -f /distributed/sql/02_productos.sql
for _ in $(seq 1 120); do
    listos=0
    for y in b c; do
        [[ "$(psql_en "$y" -Atc "SELECT count(*) FROM ref.productos")" == "5000" ]] && listos=$((listos + 1))
    done
    [[ "$listos" == "2" ]] && break
    sleep 1
done

log "generando y distribuyendo clientes, pedidos y detalle desde nodo_a"
psql_en a -q -f /distributed/sql/02_carga.sql
esperar_replicas

log "creando indices $INDICE sobre id_cliente en los tres nodos"
for n in a b c; do
    psql_en "$n" -q -c "SET dist.metodo = '$INDICE'" -f /distributed/sql/05_indices.sql
done

log "verificando fragmentacion"
psql_en a -f /distributed/sql/06_verificar.sql | tee results/verificacion_fragmentos.txt

./scripts/latencias.sh on
./scripts/validar_latencias.sh
log "entorno distribuido listo"

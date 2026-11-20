#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

PSQL=(docker compose exec -T db psql -U postgres -d bd2 -v ON_ERROR_STOP=1 -Atq)

esperar() {
    for _ in $(seq 1 60); do
        if docker compose exec -T db pg_isready -U postgres -d bd2 >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    echo "el servidor no respondio" >&2
    exit 1
}

verificar() {
    local etapa="$1"
    local res
    res=$("${PSQL[@]}" -c "SELECT ttree_check('i_reinicio_tt')")
    echo "$etapa: $res"
    [[ "$res" == OK* ]] || { echo "FALLO: $etapa" >&2; exit 1; }
    res=$("${PSQL[@]}" <<'SQL'
SET enable_seqscan = off; SET enable_bitmapscan = off;
CREATE TEMP TABLE a AS SELECT id FROM i_reinicio WHERE k BETWEEN 1000 AND 9000;
SET enable_seqscan = on; SET enable_indexscan = off;
CREATE TEMP TABLE b AS SELECT id FROM i_reinicio WHERE k BETWEEN 1000 AND 9000;
SELECT (SELECT count(*) FROM (SELECT * FROM a EXCEPT ALL SELECT * FROM b) x)
     + (SELECT count(*) FROM (SELECT * FROM b EXCEPT ALL SELECT * FROM a) y);
SQL
)
    echo "$etapa: diferencias indice/heap=$res"
    [[ "$res" == "0" ]] || { echo "FALLO: $etapa" >&2; exit 1; }
}

"${PSQL[@]}" <<'SQL'
DROP TABLE IF EXISTS i_reinicio;
CREATE TABLE i_reinicio (id serial, k int);
INSERT INTO i_reinicio (k) SELECT (g * 7919) % 20000 FROM generate_series(1, 30000) g;
CREATE INDEX i_reinicio_tt ON i_reinicio USING ttree (k);
CHECKPOINT;
INSERT INTO i_reinicio (k) SELECT (g * 104729) % 20000 FROM generate_series(1, 20000) g;
DELETE FROM i_reinicio WHERE id % 5 = 0;
VACUUM i_reinicio;
INSERT INTO i_reinicio (k) SELECT (g * 31) % 20000 FROM generate_series(1, 5000) g;
SQL
verificar "antes del reinicio"

docker compose restart db >/dev/null
esperar
verificar "tras reinicio ordenado"

"${PSQL[@]}" -c "INSERT INTO i_reinicio (k) SELECT (g * 13) % 20000 FROM generate_series(1, 20000) g" >/dev/null
docker compose kill -s SIGKILL db >/dev/null
docker compose up -d --wait db >/dev/null
esperar
verificar "tras caida y recuperacion desde WAL"

"${PSQL[@]}" -c "DROP TABLE i_reinicio"
echo "==== REINICIO OK ===="

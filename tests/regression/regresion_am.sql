\set ON_ERROR_STOP on
\set QUIET on
\pset pager off
\o /dev/null
SET client_min_messages = notice;
SELECT setseed(0.17);

CREATE EXTENSION IF NOT EXISTS ttree;

DROP TABLE IF EXISTS r_parcial, r_vac, r_ext, r_tx CASCADE;

CREATE OR REPLACE FUNCTION pg_temp.ids(q text, usar_idx boolean) RETURNS bigint[]
LANGUAGE plpgsql AS $$
DECLARE r bigint[];
BEGIN
    IF usar_idx THEN
        SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = on;
    ELSE
        SET LOCAL enable_seqscan = on; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = off;
        SET LOCAL enable_indexonlyscan = off;
    END IF;
    EXECUTE 'SELECT coalesce(array_agg(id ORDER BY id), ''{}'') FROM (' || q || ') x' INTO r;
    RETURN r;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.igual(q text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    IF pg_temp.ids(q, true) IS DISTINCT FROM pg_temp.ids(q, false) THEN
        RAISE EXCEPTION 'resultado distinto al heap: %', q;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.contar(q text, usar_idx boolean) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE r bigint;
BEGIN
    IF usar_idx THEN
        SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
    ELSE
        SET LOCAL enable_indexscan = off; SET LOCAL enable_indexonlyscan = off; SET LOCAL enable_bitmapscan = off;
    END IF;
    EXECUTE q INTO r;
    RETURN r;
END $$;

\echo '-- R1: indice parcial sin condicion sobre la clave y filas con NULL'
CREATE TABLE r_parcial (id serial, a int, b int);
INSERT INTO r_parcial (a, b)
SELECT CASE WHEN g % 5 = 0 THEN NULL ELSE g END, g % 2 FROM generate_series(1, 4000) g;
CREATE INDEX r_parcial_tt ON r_parcial USING ttree (a) WHERE b = 1;
VACUUM ANALYZE r_parcial;
DO $$
DECLARE c_idx bigint; c_heap bigint;
BEGIN
    c_idx := pg_temp.contar('SELECT count(*) FROM r_parcial WHERE b = 1', true);
    c_heap := pg_temp.contar('SELECT count(*) FROM r_parcial WHERE b = 1', false);
    IF c_idx <> c_heap THEN
        RAISE EXCEPTION 'R1 count(*): indice=% heap=%', c_idx, c_heap;
    END IF;
END $$;
SELECT pg_temp.igual('SELECT id FROM r_parcial WHERE b = 1');
SELECT pg_temp.igual('SELECT id FROM r_parcial WHERE b = 1 AND a BETWEEN 100 AND 900');
SELECT pg_temp.igual('SELECT id FROM r_parcial WHERE b = 1 AND a IS NULL');
SELECT pg_temp.igual('SELECT id FROM r_parcial WHERE b = 1 AND a IS NOT NULL');

\echo '-- R2: VACUUM con varias pasadas sobre el indice'
CREATE TABLE r_vac (id serial, k int) WITH (autovacuum_enabled = off);
INSERT INTO r_vac (k) SELECT g FROM generate_series(1, 80000) g;
CREATE INDEX r_vac_tt ON r_vac USING ttree (k);
DELETE FROM r_vac WHERE id % 2 = 0;
SET maintenance_work_mem = '64kB';
VACUUM r_vac;
RESET maintenance_work_mem;
DO $$
DECLARE t_heap real; t_idx real; r text;
BEGIN
    SELECT reltuples INTO t_heap FROM pg_class WHERE relname = 'r_vac';
    SELECT reltuples INTO t_idx FROM pg_class WHERE relname = 'r_vac_tt';
    RAISE NOTICE 'R2 reltuples heap=% indice=%', t_heap, t_idx;
    IF t_idx <> t_heap THEN
        RAISE EXCEPTION 'R2: el conteo del indice tras VACUUM (%) no coincide con el heap (%)', t_idx, t_heap;
    END IF;
    r := ttree_check('r_vac_tt');
    IF r NOT LIKE 'OK%' THEN RAISE EXCEPTION 'R2 ttree_check: %', r; END IF;
END $$;
SELECT pg_temp.igual('SELECT id FROM r_vac WHERE k BETWEEN 1000 AND 1200');

\echo '-- R3: extremos de int4, duplicados, operadores y condiciones combinadas'
CREATE TABLE r_ext (id serial, k int);
INSERT INTO r_ext (k)
SELECT (ARRAY[-2147483648, -2147483647, -1, 0, 1, 2147483646, 2147483647])[1 + g % 7]
FROM generate_series(1, 700) g;
INSERT INTO r_ext (k) SELECT floor(random() * 50)::int FROM generate_series(1, 3000);
INSERT INTO r_ext (k) VALUES (NULL), (NULL);
CREATE INDEX r_ext_tt ON r_ext USING ttree (k);
ANALYZE r_ext;
DO $$
DECLARE v int; op text;
BEGIN
    FOREACH v IN ARRAY ARRAY[-2147483648, -2147483647, -1, 0, 1, 25, 2147483646, 2147483647] LOOP
        FOREACH op IN ARRAY ARRAY['<', '<=', '=', '>=', '>'] LOOP
            PERFORM pg_temp.igual(format('SELECT id FROM r_ext WHERE k %s %s', op, v));
        END LOOP;
    END LOOP;
END $$;
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k BETWEEN -2147483648 AND 2147483647');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k BETWEEN 10 AND 20');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k BETWEEN 20 AND 10');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k > 5 AND k < 6');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k >= 5 AND k <= 5 AND k = 5');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k = 7 AND k = 8');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k IS NULL');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k = ANY (ARRAY[3, 7, 2147483647])');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k = 7::bigint');
SELECT pg_temp.igual('SELECT id FROM r_ext WHERE k < 3000000000::bigint');
DO $$
DECLARE a bigint[]; b bigint[];
BEGIN
    SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off;
    SELECT array_agg(k) INTO a FROM (SELECT k FROM r_ext WHERE k BETWEEN 0 AND 49 ORDER BY k) s;
    SET LOCAL enable_seqscan = on; SET LOCAL enable_indexscan = off;
    SELECT array_agg(k) INTO b FROM (SELECT k FROM r_ext WHERE k BETWEEN 0 AND 49 ORDER BY k) s;
    IF a IS DISTINCT FROM b THEN RAISE EXCEPTION 'R3: ORDER BY difiere'; END IF;
END $$;

\echo '-- R4: transacciones abortadas, TRUNCATE y CREATE INDEX CONCURRENTLY'
CREATE TABLE r_tx (id serial, k int);
CREATE INDEX r_tx_tt ON r_tx USING ttree (k);
INSERT INTO r_tx (k) SELECT g % 100 FROM generate_series(1, 2000) g;
BEGIN;
INSERT INTO r_tx (k) SELECT 5 FROM generate_series(1, 500);
ROLLBACK;
SELECT pg_temp.igual('SELECT id FROM r_tx WHERE k = 5');
VACUUM r_tx;
SELECT pg_temp.igual('SELECT id FROM r_tx WHERE k = 5');
DO $$ BEGIN
    IF ttree_check('r_tx_tt') NOT LIKE 'OK%' THEN RAISE EXCEPTION 'R4 ttree_check'; END IF;
END $$;
TRUNCATE r_tx;
DO $$ BEGIN
    IF ttree_check('r_tx_tt') <> 'OK nodos=0 entradas=0 borradas=0 altura=0' THEN
        RAISE EXCEPTION 'R4: TRUNCATE no dejo el indice vacio';
    END IF;
END $$;
INSERT INTO r_tx (k) SELECT g FROM generate_series(1, 300) g;
SELECT pg_temp.igual('SELECT id FROM r_tx WHERE k BETWEEN 10 AND 40');
CREATE INDEX CONCURRENTLY r_tx_tt2 ON r_tx USING ttree (k);
DO $$ BEGIN
    IF ttree_check('r_tx_tt2') NOT LIKE 'OK%' THEN RAISE EXCEPTION 'R4 CIC ttree_check'; END IF;
END $$;

\echo '-- R5: el planner usa el indice en consultas selectivas (EXPLAIN ANALYZE, BUFFERS)'
DROP INDEX r_tx_tt2;
INSERT INTO r_tx (k) SELECT floor(random() * 20000)::int FROM generate_series(1, 40000);
ANALYZE r_tx;
DO $$
DECLARE r record; plan text := '';
BEGIN
    FOR r IN EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF) SELECT * FROM r_tx WHERE k = 17 LOOP
        plan := plan || r."QUERY PLAN" || E'\n';
    END LOOP;
    RAISE NOTICE E'R5 plan:\n%', plan;
    IF plan NOT LIKE '%Index Scan using r_tx_tt%' THEN
        RAISE EXCEPTION 'R5: el planner no eligio el T-Tree';
    END IF;
END $$;

DROP TABLE r_parcial, r_vac, r_ext, r_tx;
\echo '==== REGRESION OK ===='

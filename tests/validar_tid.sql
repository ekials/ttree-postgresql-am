







\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = notice;
SELECT setseed(0.42);

CREATE EXTENSION IF NOT EXISTS ttree;

DROP TABLE IF EXISTS t_build, t_ins, t_asc, t_desc, t_vacia CASCADE;





CREATE OR REPLACE FUNCTION pg_temp.comparar(tabla regclass, idx regclass, n_rangos int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    kmin int; kmax int; lo int; hi int;
    c_idx bigint; c_heap bigint; s_idx bigint; s_heap bigint; malos bigint;
BEGIN
    EXECUTE format('SELECT min(k), max(k) FROM %s', tabla) INTO kmin, kmax;
    IF kmin IS NULL THEN RETURN; END IF;

    FOR i IN 1..n_rangos LOOP
        lo := kmin + floor(random() * (kmax - kmin + 1))::int;
        hi := lo + floor(random() * 200)::int;
        IF i % 10 = 0 THEN hi := lo; END IF;          

        EXECUTE format('SELECT count(*), coalesce(sum(t.id),0)
                          FROM ttree_lookup(%L, %s, %s) l JOIN %s t ON t.ctid = l.tid',
                       idx, lo, hi, tabla) INTO c_idx, s_idx;
        EXECUTE format('SELECT count(*), coalesce(sum(id),0) FROM %s WHERE k BETWEEN %s AND %s',
                       tabla, lo, hi) INTO c_heap, s_heap;

        IF c_idx <> c_heap OR s_idx <> s_heap THEN
            RAISE EXCEPTION '% [%,%]: indice=(%,%) heap=(%,%)',
                idx, lo, hi, c_idx, s_idx, c_heap, s_heap;
        END IF;
    END LOOP;

    
    EXECUTE format('SELECT count(*) FROM ttree_lookup(%L, %s, %s) l
                      LEFT JOIN %s t ON t.ctid = l.tid
                     WHERE t.id IS NULL OR t.k <> l.key',
                   idx, kmin, kmax, tabla) INTO malos;
    IF malos <> 0 THEN
        RAISE EXCEPTION '% : % TIDs invalidos o con clave distinta', idx, malos;
    END IF;

    
    EXECUTE format('SELECT count(*) FROM ttree_lookup(%L, %s, %s)', idx, kmin, kmax) INTO c_idx;
    EXECUTE format('SELECT count(*) FROM %s', tabla) INTO c_heap;
    IF c_idx <> c_heap THEN
        RAISE EXCEPTION '% : rango total devuelve % filas, heap tiene %', idx, c_idx, c_heap;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.check_ok(idx regclass)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    r := ttree_check(idx);
    RAISE NOTICE '%  ->  %', idx, r;
    IF r NOT LIKE 'OK%' THEN RAISE EXCEPTION 'ttree_check fallo: %', r; END IF;
END $$;




CREATE TABLE t_build (id serial, k int);
INSERT INTO t_build (k) SELECT floor(random() * 3000)::int FROM generate_series(1, 30000);
CREATE INDEX t_build_tt ON t_build USING ttree (k);
SELECT pg_temp.check_ok('t_build_tt');
SELECT pg_temp.comparar('t_build', 't_build_tt', 300);





CREATE TABLE t_ins (id serial, k int);
CREATE INDEX t_ins_tt ON t_ins USING ttree (k);
INSERT INTO t_ins (k) SELECT floor(random() * 3000)::int FROM generate_series(1, 20000);
SELECT pg_temp.check_ok('t_ins_tt');
SELECT pg_temp.comparar('t_ins', 't_ins_tt', 300);




CREATE TABLE t_asc (id serial, k int);
CREATE INDEX t_asc_tt ON t_asc USING ttree (k);
INSERT INTO t_asc (k) SELECT g FROM generate_series(1, 10000) g;
SELECT pg_temp.check_ok('t_asc_tt');
SELECT pg_temp.comparar('t_asc', 't_asc_tt', 150);

CREATE TABLE t_desc (id serial, k int);
CREATE INDEX t_desc_tt ON t_desc USING ttree (k);
INSERT INTO t_desc (k) SELECT g FROM generate_series(10000, 1, -1) g;
SELECT pg_temp.check_ok('t_desc_tt');
SELECT pg_temp.comparar('t_desc', 't_desc_tt', 150);




INSERT INTO t_build (k) SELECT floor(random() * 5000)::int FROM generate_series(1, 10000);
SELECT pg_temp.check_ok('t_build_tt');
SELECT pg_temp.comparar('t_build', 't_build_tt', 200);





DELETE FROM t_ins WHERE id % 3 = 0;
VACUUM t_ins;
SELECT pg_temp.check_ok('t_ins_tt');
SELECT pg_temp.comparar('t_ins', 't_ins_tt', 200);
INSERT INTO t_ins (k) SELECT floor(random() * 3000)::int FROM generate_series(1, 5000);
SELECT pg_temp.check_ok('t_ins_tt');
SELECT pg_temp.comparar('t_ins', 't_ins_tt', 200);




CREATE TABLE t_vacia (id serial, k int);
CREATE INDEX t_vacia_tt ON t_vacia USING ttree (k);
SELECT pg_temp.check_ok('t_vacia_tt');
INSERT INTO t_vacia (k) VALUES (NULL), (NULL), (7);
SELECT pg_temp.check_ok('t_vacia_tt');
DO $$ BEGIN
    IF (SELECT count(*) FROM ttree_lookup('t_vacia_tt', -2147483648, 2147483647)) <> 1 THEN
        RAISE EXCEPTION 'los NULL no deben indexarse';
    END IF;
END $$;

REINDEX INDEX t_ins_tt;
SELECT pg_temp.check_ok('t_ins_tt');
SELECT pg_temp.comparar('t_ins', 't_ins_tt', 100);

DO $$ BEGIN
    BEGIN
        PERFORM ttree_check('t_ins'::regclass);
        RAISE EXCEPTION 'debio fallar: t_ins no es un indice';
    EXCEPTION WHEN wrong_object_type OR undefined_table OR feature_not_supported THEN
        NULL;
    END;
END $$;


DO $$
DECLARE r record; usado boolean := false; a bigint; b bigint;
BEGIN
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_bitmapscan = off;
    FOR r IN EXECUTE 'EXPLAIN SELECT * FROM t_build WHERE k = 5' LOOP
        IF r."QUERY PLAN" ILIKE '%t_build_tt%' THEN usado := true; END IF;
    END LOOP;
    IF NOT usado THEN RAISE EXCEPTION 'el planner no uso el indice ttree'; END IF;

    SELECT count(*) INTO a FROM t_build WHERE k BETWEEN 100 AND 400;   
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_seqscan = on;
    SELECT count(*) INTO b FROM t_build WHERE k BETWEEN 100 AND 400;   
    IF a <> b THEN RAISE EXCEPTION 'index scan=% pero seqscan=%', a, b; END IF;
END $$;

\echo
\echo ==== TODAS LAS PRUEBAS OK ====
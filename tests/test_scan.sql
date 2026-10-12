\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS ttree;
DROP TABLE IF EXISTS s CASCADE;
CREATE TABLE s (id serial, k int);

INSERT INTO s (k) SELECT (random()*2000)::int FROM generate_series(1,20000);
INSERT INTO s (k) VALUES (-2147483648),(-2147483648),(2147483647),(2147483647),(NULL),(NULL),(0);
CREATE INDEX s_tt ON s USING ttree (k);
ANALYZE s;


SET enable_seqscan = off;
SET enable_bitmapscan = off;
\echo 
EXPLAIN (COSTS OFF) SELECT * FROM s WHERE k = 5;
EXPLAIN (COSTS OFF) SELECT * FROM s WHERE k BETWEEN 10 AND 20;
EXPLAIN (COSTS OFF) SELECT * FROM s WHERE k > 1990;


CREATE OR REPLACE FUNCTION pg_temp.contar(q text, usar_idx boolean) RETURNS bigint[] AS $$
DECLARE r bigint[];
BEGIN
  IF usar_idx THEN SET LOCAL enable_seqscan = off; SET LOCAL enable_bitmapscan = off; SET LOCAL enable_indexscan = on;
  ELSE SET LOCAL enable_seqscan = on; SET LOCAL enable_indexscan = off; SET LOCAL enable_bitmapscan = off; END IF;
  EXECUTE 'SELECT coalesce(array_agg(id ORDER BY id), ''{}'') FROM (' || q || ') x' INTO r;
  RETURN r;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE ops text[] := ARRAY['=','<','<=','>','>=']; op text; v int; q text; n int := 0; mal int := 0;
        a int; b int; usado boolean;
BEGIN
  FOREACH op IN ARRAY ops LOOP
    FOR i IN 1..60 LOOP
      v := (random()*2200 - 100)::int;
      q := format('SELECT id FROM s WHERE k %s %s', op, v);
      IF pg_temp.contar(q, true) <> pg_temp.contar(q, false) THEN mal := mal + 1; RAISE WARNING 'DIFIERE: %', q; END IF;
      n := n + 1;
    END LOOP;
    
    FOREACH v IN ARRAY ARRAY[-2147483648, 2147483647, 0] LOOP
      q := format('SELECT id FROM s WHERE k %s %s', op, v);
      IF pg_temp.contar(q, true) <> pg_temp.contar(q, false) THEN mal := mal + 1; RAISE WARNING 'DIFIERE: %', q; END IF;
      n := n + 1;
    END LOOP;
  END LOOP;
  FOR i IN 1..150 LOOP
    a := (random()*2000)::int; b := a + (random()*300)::int;
    q := format('SELECT id FROM s WHERE k >= %s AND k <= %s', a, b);
    IF pg_temp.contar(q, true) <> pg_temp.contar(q, false) THEN mal := mal + 1; RAISE WARNING 'DIFIERE: %', q; END IF;
    q := format('SELECT id FROM s WHERE k > %s AND k < %s', b, a);   
    IF pg_temp.contar(q, true) <> pg_temp.contar(q, false) THEN mal := mal + 1; RAISE WARNING 'DIFIERE: %', q; END IF;
    n := n + 2;
  END LOOP;
  RAISE NOTICE 'consultas comparadas=% diferencias=%', n, mal;
  IF mal > 0 THEN RAISE EXCEPTION 'el escaneo difiere del seqscan'; END IF;
END $$;


DELETE FROM s WHERE k % 3 = 0;
VACUUM s;
INSERT INTO s (k) SELECT (random()*2000)::int FROM generate_series(1,5000);
DO $$
DECLARE q text; mal int := 0; a int; b int;
BEGIN
  FOR i IN 1..200 LOOP
    a := (random()*2000)::int; b := a + (random()*200)::int;
    q := format('SELECT id FROM s WHERE k BETWEEN %s AND %s', a, b);
    IF pg_temp.contar(q, true) <> pg_temp.contar(q, false) THEN mal := mal + 1; END IF;
  END LOOP;
  RAISE NOTICE 'post-VACUUM: diferencias=%', mal;
  IF mal > 0 THEN RAISE EXCEPTION 'difiere tras VACUUM'; END IF;
END $$;
SELECT ttree_check('s_tt');


CREATE TEMP TABLE o AS SELECT (random()*2000)::int AS v FROM generate_series(1,300);
SET enable_hashjoin = off; SET enable_mergejoin = off;
\echo 
EXPLAIN (COSTS OFF) SELECT count(*) FROM o JOIN s ON s.k = o.v;
SELECT count(*) AS join_con_indice FROM o JOIN s ON s.k = o.v;
SET enable_indexscan = off; SET enable_seqscan = on; SET enable_nestloop = on;
SELECT count(*) AS join_seqscan FROM o JOIN s ON s.k = o.v;
\echo ==== ESCANEO OK ====

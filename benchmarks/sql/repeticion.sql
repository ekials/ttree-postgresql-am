\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
SET max_parallel_workers_per_gather = 0;
SET jit = off;
SET enable_bitmapscan = off;
SET enable_indexonlyscan = off;

DROP TABLE IF EXISTS public.t;
CREATE TABLE public.t WITH (autovacuum_enabled = off) AS
    SELECT k, ord AS pay FROM bench.:"base" ORDER BY ord;
VACUUM (ANALYZE) public.t;
CHECKPOINT;

\if :con_indice
SELECT bench.registrar(:'cfg', :'ds', :n, :'metodo', :rep, 'construccion',
                       bench.construir(:'metodo'), NULL, NULL, NULL, NULL);
ANALYZE public.t;
SELECT bench.registrar(:'cfg', :'ds', :n, :'metodo', :rep, 'tamano_inicial',
                       NULL, NULL, NULL, NULL, pg_relation_size('public.t_idx'));
SELECT pg_prewarm('public.t_idx');
SET enable_seqscan = off;
\endif
SELECT pg_prewarm('public.t');
SELECT bench.registrar(:'cfg', :'ds', :n, :'metodo', :rep, 'tamano_tabla',
                       NULL, NULL, NULL, NULL, pg_relation_size('public.t'));

SELECT bench.lectura(:'cfg', :'ds', :n, :'metodo', :rep, 'w1', 100);
SELECT bench.lectura(:'cfg', :'ds', :n, :'metodo', :rep, 'w1');
SELECT bench.lectura(:'cfg', :'ds', :n, :'metodo', :rep, 'w2');
SELECT bench.lectura(:'cfg', :'ds', :n, :'metodo', :rep, 'w4');
\if :planes
SELECT bench.plan(:'cfg', :'ds', :n, :'metodo', 'w1');
SELECT bench.plan(:'cfg', :'ds', :n, :'metodo', 'w2');
SELECT bench.plan(:'cfg', :'ds', :n, :'metodo', 'w4');
\endif
SELECT bench.escritura(:'cfg', :'ds', :n, :'metodo', :rep);

\if :con_indice
SELECT bench.registrar(:'cfg', :'ds', :n, :'metodo', :rep, 'tamano_final',
                       NULL, NULL, NULL, NULL, pg_relation_size('public.t_idx'));
\if :es_ttree
SELECT ttree_check('public.t_idx') LIKE 'OK%' AS chk_ok \gset
\if :chk_ok
SELECT bench.registrar(:'cfg', :'ds', :n, :'metodo', :rep, 'ttree_check_ok',
                       NULL, NULL, NULL, NULL, NULL);
\else
\echo 'ttree_check fallo'
\o
SELECT ttree_check('public.t_idx');
SELECT 1 / 0;
\endif
\endif
\endif

DROP TABLE public.t;

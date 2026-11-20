\set ON_ERROR_STOP on
CREATE EXTENSION IF NOT EXISTS ttree;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;
CREATE SCHEMA IF NOT EXISTS bench;

CREATE TABLE IF NOT EXISTS bench.resultados (
    config      text NOT NULL,
    dataset     text NOT NULL,
    n           int NOT NULL,
    metodo      text NOT NULL,
    rep         int NOT NULL,
    medida      text NOT NULL,
    ms          double precision,
    operaciones int,
    filas       bigint,
    control     numeric,
    bytes       bigint,
    registrado  timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS bench.planes (
    config  text,
    dataset text,
    n       int,
    metodo  text,
    medida  text,
    plan    text
);

CREATE OR REPLACE FUNCTION bench.buscar(claves anyarray, OUT ms double precision, OUT filas bigint, OUT control numeric)
LANGUAGE plpgsql AS $$
DECLARE
    c bigint; s bigint; t0 timestamptz;
BEGIN
    filas := 0; control := 0;
    t0 := clock_timestamp();
    FOR i IN 1 .. coalesce(array_length(claves, 1), 0) LOOP
        SELECT count(*), coalesce(sum(pay), 0) INTO c, s FROM public.t WHERE k = claves[i];
        filas := filas + c; control := control + s;
    END LOOP;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
END $$;

CREATE OR REPLACE FUNCTION bench.rangos(lo anyarray, hi anyarray, OUT ms double precision, OUT filas bigint, OUT control numeric)
LANGUAGE plpgsql AS $$
DECLARE
    c bigint; s bigint; t0 timestamptz;
BEGIN
    filas := 0; control := 0;
    t0 := clock_timestamp();
    FOR i IN 1 .. coalesce(array_length(lo, 1), 0) LOOP
        SELECT count(*), coalesce(sum(pay), 0) INTO c, s FROM public.t WHERE k BETWEEN lo[i] AND hi[i];
        filas := filas + c; control := control + s;
    END LOOP;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
END $$;

CREATE OR REPLACE FUNCTION bench.insertar(claves anyarray, pay0 int, OUT ms double precision, OUT filas bigint)
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz;
BEGIN
    t0 := clock_timestamp();
    FOR i IN 1 .. coalesce(array_length(claves, 1), 0) LOOP
        INSERT INTO public.t (k, pay) VALUES (claves[i], pay0 + i);
    END LOOP;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    filas := coalesce(array_length(claves, 1), 0);
END $$;

CREATE OR REPLACE FUNCTION bench.tipo(ds text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN ds IN ('d4', 'd5') THEN 'txt' ELSE 'int' END $$;

CREATE OR REPLACE FUNCTION bench.workload(ds text, n int, w text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT format('bench.%I', format('w_%s_%s_%s', ds, n, w)) $$;

CREATE OR REPLACE FUNCTION bench.registrar(cfg text, ds text, n int, metodo text, rep int, medida text,
                                           ms double precision, operaciones int, filas bigint,
                                           control numeric, bytes bigint)
RETURNS void LANGUAGE sql AS $$
    INSERT INTO bench.resultados (config, dataset, n, metodo, rep, medida, ms, operaciones, filas, control, bytes)
    VALUES (cfg, ds, n, metodo, rep, medida, ms, operaciones, filas, control, bytes)
$$;

CREATE OR REPLACE FUNCTION bench.construir(metodo text) RETURNS double precision
LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz;
BEGIN
    t0 := clock_timestamp();
    EXECUTE format('CREATE INDEX t_idx ON public.t USING %s (k)', metodo);
    RETURN extract(epoch FROM clock_timestamp() - t0) * 1000;
END $$;

CREATE OR REPLACE FUNCTION bench.lectura(cfg text, ds text, n int, metodo text, rep int, w text, limite int DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    wl text := bench.workload(ds, n, w);
    ai int[]; bi int[]; at text[]; bt text[];
    r record; nops int;
BEGIN
    IF bench.tipo(ds) = 'int' THEN
        EXECUTE format('SELECT array_agg(a::int ORDER BY op), array_agg(b::int ORDER BY op) FROM (SELECT * FROM %s ORDER BY op LIMIT %s) x',
                       wl, coalesce(limite::text, 'ALL')) INTO ai, bi;
        nops := array_length(ai, 1);
        IF w = 'w4' THEN r := bench.rangos(ai, bi); ELSE r := bench.buscar(ai); END IF;
    ELSE
        EXECUTE format('SELECT array_agg(a ORDER BY op), array_agg(b ORDER BY op) FROM (SELECT * FROM %s ORDER BY op LIMIT %s) x',
                       wl, coalesce(limite::text, 'ALL')) INTO at, bt;
        nops := array_length(at, 1);
        IF w = 'w4' THEN r := bench.rangos(at, bt); ELSE r := bench.buscar(at); END IF;
    END IF;
    IF limite IS NULL THEN
        PERFORM bench.registrar(cfg, ds, n, metodo, rep, w, r.ms, nops, r.filas, r.control, NULL);
    END IF;
END $$;

CREATE OR REPLACE FUNCTION bench.escritura(cfg text, ds text, n int, metodo text, rep int)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    wl text := bench.workload(ds, n, 'w3');
    ai int[]; at text[]; r record;
BEGIN
    IF bench.tipo(ds) = 'int' THEN
        EXECUTE format('SELECT array_agg(a::int ORDER BY op) FROM %s', wl) INTO ai;
        r := bench.insertar(ai, n);
    ELSE
        EXECUTE format('SELECT array_agg(a ORDER BY op) FROM %s', wl) INTO at;
        r := bench.insertar(at, n);
    END IF;
    PERFORM bench.registrar(cfg, ds, n, metodo, rep, 'w3', r.ms, r.filas::int, r.filas, NULL, NULL);
END $$;

CREATE OR REPLACE FUNCTION bench.plan(cfg text, ds text, n int, metodo text, w text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    wl text := bench.workload(ds, n, w);
    a text; b text; q text; linea record; texto text := '';
BEGIN
    EXECUTE format('SELECT a, b FROM %s ORDER BY op LIMIT 1', wl) INTO a, b;
    IF w = 'w4' THEN
        q := format('SELECT count(*), sum(pay) FROM public.t WHERE k BETWEEN %L AND %L', a, b);
    ELSE
        q := format('SELECT count(*), sum(pay) FROM public.t WHERE k = %L', a);
    END IF;
    FOR linea IN EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, COSTS ON) ' || q LOOP
        texto := texto || linea."QUERY PLAN" || E'\n';
    END LOOP;
    INSERT INTO bench.planes VALUES (cfg, ds, n, metodo, w, q || E'\n' || texto);
END $$;

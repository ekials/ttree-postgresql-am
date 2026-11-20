\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION dist.bytes_red(OUT rx bigint, OUT tx bigint) LANGUAGE sql AS $$
    SELECT trim(pg_read_file('/sys/class/net/eth0/statistics/rx_bytes'))::bigint,
           trim(pg_read_file('/sys/class/net/eth0/statistics/tx_bytes'))::bigint
$$;

CREATE OR REPLACE FUNCTION dist.cliente_en(estrategia text, nodo text, desde int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE r int;
BEGIN
    EXECUTE format('SELECT id_cliente FROM %I.clientes WHERE id_cliente >= %s
                    AND tableoid::regclass::text LIKE ''%%clientes\_%s'' ORDER BY id_cliente LIMIT 1',
                   'g_' || estrategia, desde, nodo) INTO r;
    RETURN r;
END $$;

CREATE OR REPLACE PROCEDURE dist.medir(experimento text, estrategia text, indice text, latencia text,
                                       consulta text, sql text, reps int)
LANGUAGE plpgsql AS $$
DECLARE
    t0 timestamptz; ms double precision; n bigint; b0 record; b1 record;
BEGIN
    EXECUTE format('SET search_path = %I, public', 'g_' || estrategia);
    EXECUTE sql;
    COMMIT;
    FOR i IN 1 .. reps LOOP
        EXECUTE format('SET search_path = %I, public', 'g_' || estrategia);
        b0 := dist.bytes_red();
        t0 := clock_timestamp();
        EXECUTE sql;
        GET DIAGNOSTICS n = ROW_COUNT;
        COMMIT;
        ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
        b1 := dist.bytes_red();
        INSERT INTO dist.resultados (experimento, estrategia, indice, latencia, consulta, rep, ms, filas, bytes_rx, bytes_tx, detalle)
        VALUES (experimento, estrategia, indice, latencia, consulta, i, ms, n, b1.rx - b0.rx, b1.tx - b0.tx, sql);
        COMMIT;
    END LOOP;
    RESET search_path;
END $$;

CREATE OR REPLACE PROCEDURE dist.plan(estrategia text, indice text, consulta text, sql text)
LANGUAGE plpgsql AS $$
DECLARE linea record; texto text := '';
BEGIN
    EXECUTE format('SET search_path = %I, public', 'g_' || estrategia);
    FOR linea IN EXECUTE 'EXPLAIN (ANALYZE, VERBOSE, BUFFERS, COSTS OFF) ' || sql LOOP
        texto := texto || linea."QUERY PLAN" || E'\n';
    END LOOP;
    INSERT INTO dist.resultados (experimento, estrategia, indice, consulta, detalle)
    VALUES ('plan', estrategia, indice, consulta, sql || E'\n' || texto);
    RESET search_path;
END $$;

CREATE TABLE IF NOT EXISTS dist.sonda (
    estrategia text, instante timestamptz, consulta text, ok boolean, ms double precision, error text
);

CREATE OR REPLACE PROCEDURE dist.sonda(estrategia text, segundos int, pausa double precision DEFAULT 0.2)
LANGUAGE plpgsql AS $$
DECLARE
    fin timestamptz := clock_timestamp() + make_interval(secs => segundos);
    q record; t0 timestamptz; err text; ok boolean;
    c_a int := dist.cliente_en(estrategia, 'a', 1000);
    c_c int := dist.cliente_en(estrategia, 'c', 200000);
BEGIN
    COMMIT;
    WHILE clock_timestamp() < fin LOOP
        FOR q IN SELECT * FROM (VALUES
            ('lectura_local_a', format('SELECT count(*) FROM pedidos WHERE id_cliente = %s', c_a)),
            ('lectura_nodo_c',  format('SELECT count(*) FROM pedidos WHERE id_cliente = %s', c_c)),
            ('lectura_global',  'SELECT count(*) FROM pedidos WHERE fecha = date ''2026-01-15'''),
            ('escritura_nodo_c', format('INSERT INTO pedidos VALUES (nextval(''dist.seq_pedido''), %s, current_date, ''sonda'', 0)', c_c))
        ) v(nombre, sql) LOOP
            t0 := clock_timestamp();
            err := NULL; ok := true;
            BEGIN
                EXECUTE format('SET LOCAL search_path = %I, public', 'g_' || estrategia);
                EXECUTE q.sql;
            EXCEPTION WHEN OTHERS THEN
                ok := false; err := SQLERRM;
            END;
            IF ok THEN COMMIT; ELSE ROLLBACK; END IF;
            INSERT INTO dist.sonda VALUES (estrategia, t0, q.nombre, ok,
                                           extract(epoch FROM clock_timestamp() - t0) * 1000, err);
            COMMIT;
        END LOOP;
        PERFORM pg_sleep(pausa);
    END LOOP;
END $$;

CREATE OR REPLACE PROCEDURE dist.conmutar(estrategia text, nodo text, usar_replica boolean)
LANGUAGE plpgsql AS $$
DECLARE
    t text; f record; limites text; remota text; local_ text;
BEGIN
    SELECT * INTO f FROM dist.nodos WHERE dist.nodos.nodo = conmutar.nodo;
    limites := CASE estrategia
        WHEN 'rango' THEN format('FOR VALUES FROM (%s) TO (%s)', f.rango_lo, f.rango_hi)
        ELSE format('FOR VALUES WITH (MODULUS 3, REMAINDER %s)', f.resto)
    END;
    FOREACH t IN ARRAY ARRAY['clientes', 'pedidos', 'detalle'] LOOP
        remota := format('remoto.%I', estrategia || '_' || t || '_' || nodo);
        local_ := format('%I.%I', estrategia, t || '_' || nodo);
        IF usar_replica THEN
            EXECUTE format('ALTER TABLE %I.%I DETACH PARTITION %s', 'g_' || estrategia, t, remota);
            EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %s %s', 'g_' || estrategia, t, local_, limites);
        ELSE
            EXECUTE format('ALTER TABLE %I.%I DETACH PARTITION %s', 'g_' || estrategia, t, local_);
            EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %s %s', 'g_' || estrategia, t, remota, limites);
        END IF;
    END LOOP;
END $$;

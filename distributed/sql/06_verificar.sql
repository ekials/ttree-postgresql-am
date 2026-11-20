\set ON_ERROR_STOP on
\pset pager off
SET max_parallel_workers_per_gather = 0;

\echo '== cobertura y solapamiento de fragmentos (consultado desde el nodo A) =='
CREATE TEMP TABLE verif (estrategia text, tabla text, fragmento text, filas bigint, min_cliente int, max_cliente int);
DO $$
DECLARE e text; t text;
BEGIN
    FOREACH e IN ARRAY ARRAY['rango', 'hash'] LOOP
        FOREACH t IN ARRAY ARRAY['clientes', 'pedidos', 'detalle'] LOOP
            EXECUTE format('INSERT INTO verif SELECT %L, %L, tableoid::regclass::text, count(*), min(id_cliente), max(id_cliente)
                            FROM %I.%I GROUP BY tableoid', e, t, 'g_' || e, t);
        END LOOP;
    END LOOP;
END $$;
SELECT * FROM verif ORDER BY estrategia, tabla, fragmento;

CREATE TEMP TABLE chequeo (estrategia text, tabla text, prueba text, ok boolean, detalle text);
DO $$
DECLARE e text; t text; total bigint; stage bigint; dist_ids bigint; clave text; fuera bigint;
BEGIN
    FOREACH e IN ARRAY ARRAY['rango', 'hash'] LOOP
        FOREACH t IN ARRAY ARRAY['clientes', 'pedidos', 'detalle'] LOOP
            clave := CASE t WHEN 'clientes' THEN 'id_cliente' WHEN 'pedidos' THEN 'id_pedido' ELSE 'id_pedido, linea' END;
            EXECUTE format('SELECT count(*) FROM %I.%I', 'g_' || e, t) INTO total;
            EXECUTE format('SELECT count(*) FROM dist.%I', 'stage_' || t) INTO stage;
            EXECUTE format('SELECT count(*) FROM (SELECT DISTINCT %s FROM %I.%I) x', clave, 'g_' || e, t) INTO dist_ids;
            INSERT INTO chequeo VALUES (e, t, 'cobertura: filas globales = filas generadas', total = stage, total || ' / ' || stage);
            INSERT INTO chequeo VALUES (e, t, 'sin solapamiento: claves distintas = filas', dist_ids = total, dist_ids || ' / ' || total);
            EXECUTE format('SELECT count(*) FROM (SELECT * FROM dist.%I EXCEPT ALL SELECT * FROM %I.%I) x',
                           'stage_' || t, 'g_' || e, t) INTO fuera;
            INSERT INTO chequeo VALUES (e, t, 'reconstruccion: generadas EXCEPT ALL union de fragmentos', fuera = 0, fuera::text);
        END LOOP;
    END LOOP;
    SELECT count(*) INTO fuera FROM verif v
    WHERE v.estrategia = 'rango' AND NOT EXISTS (
        SELECT 1 FROM dist.nodos n
        WHERE v.fragmento LIKE '%\_' || n.nodo AND v.min_cliente >= n.rango_lo AND v.max_cliente < n.rango_hi);
    INSERT INTO chequeo VALUES ('rango', '*', 'predicado de rango respetado en cada fragmento', fuera = 0, fuera::text);
    SELECT count(*) INTO fuera FROM g_hash.pedidos p JOIN g_hash.clientes c ON c.id_cliente = p.id_cliente
    WHERE c.tableoid::regclass::text <> replace(p.tableoid::regclass::text, 'pedidos', 'clientes');
    INSERT INTO chequeo VALUES ('hash', 'pedidos', 'pedido en el mismo nodo que su cliente', fuera = 0, fuera::text);
END $$;
SELECT * FROM chequeo ORDER BY estrategia, tabla, prueba;
SELECT CASE WHEN bool_and(ok) THEN 'VERIFICACION OK' ELSE 'VERIFICACION FALLIDA' END AS resultado FROM chequeo;
SELECT 1 / (SELECT CASE WHEN bool_and(ok) THEN 1 ELSE 0 END FROM chequeo) AS fallar_si_hay_error;

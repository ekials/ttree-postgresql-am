\set ON_ERROR_STOP on
SELECT set_config('dist.nodo', :'nodo', false);

CREATE EXTENSION IF NOT EXISTS ttree;
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS rango;
CREATE SCHEMA IF NOT EXISTS hash;
CREATE SCHEMA IF NOT EXISTS g_rango;
CREATE SCHEMA IF NOT EXISTS g_hash;
CREATE SCHEMA IF NOT EXISTS remoto;
CREATE SCHEMA IF NOT EXISTS dist;

CREATE TABLE IF NOT EXISTS dist.nodos (
    nodo      text PRIMARY KEY,
    host      text NOT NULL,
    rango_lo  int NOT NULL,
    rango_hi  int NOT NULL,
    resto     int NOT NULL,
    replica_en text NOT NULL
);
INSERT INTO dist.nodos VALUES
    ('a', 'nodo_a',      1, 100001, 0, 'b'),
    ('b', 'nodo_b', 100001, 200001, 1, 'c'),
    ('c', 'nodo_c', 200001, 300001, 2, 'a')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS ref.productos (
    id_producto int PRIMARY KEY,
    nombre      text NOT NULL,
    categoria   text NOT NULL,
    precio      numeric(10, 2) NOT NULL
);

CREATE OR REPLACE FUNCTION dist.solo_lectura() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'la tabla % es una replica de solo lectura', TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME;
END $$;

DO $$
DECLARE
    yo text := current_setting('dist.nodo');
    e text; f record; replica boolean;
BEGIN
    FOREACH e IN ARRAY ARRAY['rango', 'hash'] LOOP
        FOR f IN SELECT * FROM dist.nodos LOOP
            replica := (f.replica_en = yo);
            CONTINUE WHEN f.nodo <> yo AND NOT replica;
            EXECUTE format('CREATE TABLE IF NOT EXISTS %I.clientes_%s (
                id_cliente int PRIMARY KEY, nombre text NOT NULL, region text NOT NULL,
                ciudad text NOT NULL, alta date NOT NULL)', e, f.nodo);
            EXECUTE format('CREATE TABLE IF NOT EXISTS %I.pedidos_%s (
                id_pedido bigint PRIMARY KEY, id_cliente int NOT NULL, fecha date NOT NULL,
                estado text NOT NULL, total numeric(12, 2) NOT NULL)', e, f.nodo);
            EXECUTE format('CREATE TABLE IF NOT EXISTS %I.detalle_%s (
                id_pedido bigint NOT NULL, linea smallint NOT NULL, id_cliente int NOT NULL,
                id_producto int NOT NULL, cantidad int NOT NULL, precio numeric(10, 2) NOT NULL,
                PRIMARY KEY (id_pedido, linea))', e, f.nodo);
            IF replica THEN
                EXECUTE format('CREATE OR REPLACE TRIGGER solo_lectura BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
                                FOR EACH ROW EXECUTE FUNCTION dist.solo_lectura()', e, 'clientes_' || f.nodo);
                EXECUTE format('CREATE OR REPLACE TRIGGER solo_lectura BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
                                FOR EACH ROW EXECUTE FUNCTION dist.solo_lectura()', e, 'pedidos_' || f.nodo);
                EXECUTE format('CREATE OR REPLACE TRIGGER solo_lectura BEFORE INSERT OR UPDATE OR DELETE ON %I.%I
                                FOR EACH ROW EXECUTE FUNCTION dist.solo_lectura()', e, 'detalle_' || f.nodo);
            ELSE
                EXECUTE format('ALTER TABLE %I.pedidos_%s ADD CONSTRAINT pedidos_cliente_fk
                                FOREIGN KEY (id_cliente) REFERENCES %I.clientes_%s', e, f.nodo, e, f.nodo);
                EXECUTE format('ALTER TABLE %I.detalle_%s ADD CONSTRAINT detalle_pedido_fk
                                FOREIGN KEY (id_pedido) REFERENCES %I.pedidos_%s', e, f.nodo, e, f.nodo);
                EXECUTE format('ALTER TABLE %I.detalle_%s ADD CONSTRAINT detalle_producto_fk
                                FOREIGN KEY (id_producto) REFERENCES ref.productos', e, f.nodo);
            END IF;
        END LOOP;
    END LOOP;
END $$;

DO $$
DECLARE
    yo text := current_setting('dist.nodo');
    f record;
BEGIN
    FOR f IN SELECT * FROM dist.nodos WHERE nodo <> yo LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_foreign_server WHERE srvname = 'nodo_' || f.nodo) THEN
            EXECUTE format('CREATE SERVER %I FOREIGN DATA WRAPPER postgres_fdw
                            OPTIONS (host %L, port ''5432'', dbname ''dist'', connect_timeout ''3'', tcp_user_timeout ''3000'',
                                     fetch_size ''1000'', batch_size ''1000'')', 'nodo_' || f.nodo, f.host);
            EXECUTE format('CREATE USER MAPPING FOR postgres SERVER %I
                            OPTIONS (user ''postgres'', password ''postgres'')', 'nodo_' || f.nodo);
        END IF;
    END LOOP;
END $$;

CREATE OR REPLACE FUNCTION dist.crear_globales() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    yo text := current_setting('dist.nodo');
    e text; t text; f record; cols text; limites text;
BEGIN
    FOREACH e IN ARRAY ARRAY['rango', 'hash'] LOOP
        FOREACH t IN ARRAY ARRAY['clientes', 'pedidos', 'detalle'] LOOP
            cols := CASE t
                WHEN 'clientes' THEN 'id_cliente int NOT NULL, nombre text NOT NULL, region text NOT NULL, ciudad text NOT NULL, alta date NOT NULL'
                WHEN 'pedidos'  THEN 'id_pedido bigint NOT NULL, id_cliente int NOT NULL, fecha date NOT NULL, estado text NOT NULL, total numeric(12, 2) NOT NULL'
                ELSE 'id_pedido bigint NOT NULL, linea smallint NOT NULL, id_cliente int NOT NULL, id_producto int NOT NULL, cantidad int NOT NULL, precio numeric(10, 2) NOT NULL'
            END;
            EXECUTE format('DROP TABLE IF EXISTS %I.%I', 'g_' || e, t);
            EXECUTE format('CREATE TABLE %I.%I (%s) PARTITION BY %s (id_cliente)',
                           'g_' || e, t, cols, CASE e WHEN 'rango' THEN 'RANGE' ELSE 'HASH' END);
            FOR f IN SELECT * FROM dist.nodos ORDER BY nodo LOOP
                limites := CASE e
                    WHEN 'rango' THEN format('FOR VALUES FROM (%s) TO (%s)', f.rango_lo, f.rango_hi)
                    ELSE format('FOR VALUES WITH (MODULUS 3, REMAINDER %s)', f.resto)
                END;
                IF f.nodo = yo THEN
                    EXECUTE format('ALTER TABLE %I.%I ATTACH PARTITION %I.%I %s',
                                   'g_' || e, t, e, t || '_' || f.nodo, limites);
                ELSE
                    EXECUTE format('DROP FOREIGN TABLE IF EXISTS remoto.%I', e || '_' || t || '_' || f.nodo);
                    EXECUTE format('CREATE FOREIGN TABLE remoto.%I PARTITION OF %I.%I %s
                                    SERVER %I OPTIONS (schema_name %L, table_name %L)',
                                   e || '_' || t || '_' || f.nodo, 'g_' || e, t, limites,
                                   'nodo_' || f.nodo, e, t || '_' || f.nodo);
                END IF;
            END LOOP;
        END LOOP;
    END LOOP;
END $$;

SELECT dist.crear_globales();

CREATE SEQUENCE IF NOT EXISTS dist.seq_pedido;
SELECT setval('dist.seq_pedido', CASE :'nodo' WHEN 'a' THEN 100000000 WHEN 'b' THEN 200000000 ELSE 300000000 END);

CREATE TABLE IF NOT EXISTS dist.resultados (
    experimento text, estrategia text, indice text, latencia text, consulta text,
    rep int, ms double precision, filas bigint, bytes_rx bigint, bytes_tx bigint, detalle text,
    registrado timestamptz DEFAULT clock_timestamp()
);

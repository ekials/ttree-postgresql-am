\set ON_ERROR_STOP on
DO $$
DECLARE
    metodo text := current_setting('dist.metodo');
    r record;
BEGIN
    FOR r IN
        SELECT n.nspname, c.relname
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname IN ('rango', 'hash') AND c.relkind = 'r'
          AND (c.relname LIKE 'pedidos\_%' OR c.relname LIKE 'detalle\_%')
    LOOP
        EXECUTE format('DROP INDEX IF EXISTS %I.%I', r.nspname, r.relname || '_cliente_idx');
        EXECUTE format('CREATE INDEX %I ON %I.%I USING %s (id_cliente)',
                       r.relname || '_cliente_idx', r.nspname, r.relname, metodo);
        IF r.relname LIKE 'pedidos\_%' THEN
            EXECUTE format('CREATE INDEX IF NOT EXISTS %I ON %I.%I (fecha)',
                           r.relname || '_fecha_idx', r.nspname, r.relname);
        END IF;
        EXECUTE format('ANALYZE %I.%I', r.nspname, r.relname);
    END LOOP;
END $$;
ANALYZE;
DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'remoto' AND c.relkind = 'f'
    LOOP
        EXECUTE format('ANALYZE remoto.%I', r.relname);
    END LOOP;
END $$;

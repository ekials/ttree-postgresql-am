\set ON_ERROR_STOP on
SELECT set_config('dist.nodo', :'nodo', false);

DO $$
DECLARE
    yo text := current_setting('dist.nodo');
BEGIN
    IF yo = 'a' AND NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'pub_ref') THEN
        CREATE PUBLICATION pub_ref FOR TABLE ref.productos;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'pub_frag_' || yo) THEN
        EXECUTE format('CREATE PUBLICATION %I FOR TABLE
                        rango.clientes_%s, rango.pedidos_%s, rango.detalle_%s,
                        hash.clientes_%s, hash.pedidos_%s, hash.detalle_%s',
                       'pub_frag_' || yo, yo, yo, yo, yo, yo, yo);
    END IF;
END $$;

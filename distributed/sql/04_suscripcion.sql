\set ON_ERROR_STOP on
\if :ref
SELECT NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'sub_ref_' || :'nodo') AS crear \gset
\if :crear
SELECT format('sub_ref_%s', :'nodo') AS sub \gset
CREATE SUBSCRIPTION :"sub"
    CONNECTION 'host=nodo_a port=5432 dbname=dist user=postgres password=postgres'
    PUBLICATION pub_ref;
\endif
\else
SELECT NOT EXISTS (SELECT 1 FROM pg_subscription WHERE subname = 'sub_frag_' || :'origen') AS crear \gset
\if :crear
SELECT format('sub_frag_%s', :'origen') AS sub,
       format('host=nodo_%s port=5432 dbname=dist user=postgres password=postgres', :'origen') AS conexion,
       format('pub_frag_%s', :'origen') AS pub \gset
CREATE SUBSCRIPTION :"sub" CONNECTION :'conexion' PUBLICATION :"pub";
\endif
\endif

\if :modo = 0
\set c random(1, 300000)
\elif :modo = 1
\set c random_zipfian(1, 300000, 1.1)
\else
\set c 300001 - random_zipfian(1, 300000, 1.1)
\endif
\set prod random(1, 5000)
BEGIN;
INSERT INTO pedidos VALUES (nextval('dist.seq_pedido'), :c, current_date, 'nuevo', 0);
INSERT INTO detalle VALUES (currval('dist.seq_pedido'), 1, :c, :prod, 1, 10);
END;

\if :modo = 0
\set c random(1, 300000)
\elif :modo = 1
\set c random_zipfian(1, 300000, 1.1)
\else
\set c 300001 - random_zipfian(1, 300000, 1.1)
\endif
\set hi :c + 99
SELECT count(*), coalesce(sum(total), 0) FROM pedidos WHERE id_cliente BETWEEN :c AND :hi;

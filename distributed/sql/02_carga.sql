\set ON_ERROR_STOP on
SET max_parallel_workers_per_gather = 0;
SELECT setseed(0.2026);

DROP TABLE IF EXISTS dist.stage_clientes, dist.stage_pedidos, dist.stage_detalle;

CREATE TABLE dist.stage_clientes AS
SELECT g AS id_cliente,
       'cliente ' || g AS nombre,
       CASE WHEN g <= 100000 THEN 'sur' WHEN g <= 200000 THEN 'centro' ELSE 'oriente' END AS region,
       CASE WHEN g <= 100000 THEN (ARRAY['arequipa', 'moquegua', 'tacna'])[1 + g % 3]
            WHEN g <= 200000 THEN (ARRAY['lima', 'ica', 'huancayo'])[1 + g % 3]
            ELSE (ARRAY['cusco', 'puno', 'abancay'])[1 + g % 3] END AS ciudad,
       date '2020-01-01' + floor(random() * 2000)::int AS alta
FROM generate_series(1, 300000) g;

CREATE TABLE dist.stage_pedidos AS
SELECT g::bigint AS id_pedido,
       1 + floor(random() * 300000)::int AS id_cliente,
       date '2025-01-01' + floor(random() * 700)::int AS fecha,
       (ARRAY['pagado', 'enviado', 'entregado', 'anulado'])[1 + floor(random() * 4)::int] AS estado,
       0::numeric(12, 2) AS total
FROM generate_series(1, 1000000) g;

CREATE TABLE dist.stage_detalle AS
SELECT p.id_pedido, l::smallint AS linea, p.id_cliente,
       1 + floor(random() * 5000)::int AS id_producto,
       1 + floor(random() * 5)::int AS cantidad,
       0::numeric(10, 2) AS precio
FROM dist.stage_pedidos p, generate_series(1, 1 + (p.id_pedido % 3)::int) l;

UPDATE dist.stage_detalle d SET precio = pr.precio FROM ref.productos pr WHERE pr.id_producto = d.id_producto;
UPDATE dist.stage_pedidos p SET total = s.total
FROM (SELECT id_pedido, sum(cantidad * precio) AS total FROM dist.stage_detalle GROUP BY id_pedido) s
WHERE s.id_pedido = p.id_pedido;
ANALYZE dist.stage_clientes, dist.stage_pedidos, dist.stage_detalle;

INSERT INTO g_rango.clientes SELECT * FROM dist.stage_clientes;
INSERT INTO g_rango.pedidos SELECT * FROM dist.stage_pedidos;
INSERT INTO g_rango.detalle SELECT * FROM dist.stage_detalle;
INSERT INTO g_hash.clientes SELECT * FROM dist.stage_clientes;
INSERT INTO g_hash.pedidos SELECT * FROM dist.stage_pedidos;
INSERT INTO g_hash.detalle SELECT * FROM dist.stage_detalle;

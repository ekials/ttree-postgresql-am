\set ON_ERROR_STOP on
\set QUIET on
\o /dev/null
SET max_parallel_workers_per_gather = 0;
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;

SELECT dist.cliente_en(:'estrategia', 'a', 1000) AS ca,
       dist.cliente_en(:'estrategia', 'b', 1000) AS cb,
       dist.cliente_en(:'estrategia', 'c', 1000) AS cc \gset

SELECT format('SELECT p.id_pedido, p.fecha, p.total, d.linea, d.id_producto, d.cantidad
               FROM pedidos p JOIN detalle d ON d.id_pedido = p.id_pedido AND d.id_cliente = p.id_cliente
               WHERE p.id_cliente = %s', :ca) AS q1a,
       format('SELECT p.id_pedido, p.fecha, p.total, d.linea, d.id_producto, d.cantidad
               FROM pedidos p JOIN detalle d ON d.id_pedido = p.id_pedido AND d.id_cliente = p.id_cliente
               WHERE p.id_cliente = %s', :cb) AS q1b,
       format('SELECT p.id_pedido, p.fecha, p.total, d.linea, d.id_producto, d.cantidad
               FROM pedidos p JOIN detalle d ON d.id_pedido = p.id_pedido AND d.id_cliente = p.id_cliente
               WHERE p.id_cliente = %s', :cc) AS q1c \gset

CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q1_cliente_local_a', :'q1a', :reps);
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q1_cliente_remoto_b', :'q1b', :reps);
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q1_cliente_remoto_c', :'q1c', :reps);
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q2_rango_1000_clientes',
    'SELECT count(*), sum(total) FROM pedidos WHERE id_cliente BETWEEN 150000 AND 150999', :reps);
SELECT least(:reps, 5) AS reps_q3 \gset
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q3_agregado_global_region',
    'SELECT c.region, count(*), sum(p.total) FROM pedidos p JOIN clientes c ON c.id_cliente = p.id_cliente GROUP BY c.region', :reps_q3);
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q4_transferencia_semana',
    'SELECT * FROM pedidos WHERE fecha BETWEEN date ''2026-03-01'' AND date ''2026-03-07''', :reps);
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q5_join_productos_replicados',
    'SELECT pr.categoria, sum(d.cantidad * d.precio) FROM detalle d JOIN ref.productos pr ON pr.id_producto = d.id_producto
     WHERE d.id_cliente BETWEEN 250000 AND 250499 GROUP BY pr.categoria', :reps);
SELECT format('INSERT INTO pedidos VALUES (nextval(''dist.seq_pedido''), %s, current_date, ''nuevo'', 0)', :ca) AS w_a,
       format('INSERT INTO pedidos VALUES (nextval(''dist.seq_pedido''), %s, current_date, ''nuevo'', 0)', :cc) AS w_c \gset
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q6_insercion_local_a', :'w_a', :reps);
CALL dist.medir('consultas', :'estrategia', :'indice', :'latencia', 'q6_insercion_remota_c', :'w_c', :reps);

\if :planes
CALL dist.plan(:'estrategia', :'indice', 'q1_cliente_remoto_c', :'q1c');
CALL dist.plan(:'estrategia', :'indice', 'q2_rango_1000_clientes',
    'SELECT count(*), sum(total) FROM pedidos WHERE id_cliente BETWEEN 150000 AND 150999');
CALL dist.plan(:'estrategia', :'indice', 'q3_agregado_global_region',
    'SELECT c.region, count(*), sum(p.total) FROM pedidos p JOIN clientes c ON c.id_cliente = p.id_cliente GROUP BY c.region');
CALL dist.plan(:'estrategia', :'indice', 'q5_join_productos_replicados',
    'SELECT pr.categoria, sum(d.cantidad * d.precio) FROM detalle d JOIN ref.productos pr ON pr.id_producto = d.id_producto
     WHERE d.id_cliente BETWEEN 250000 AND 250499 GROUP BY pr.categoria');
\endif

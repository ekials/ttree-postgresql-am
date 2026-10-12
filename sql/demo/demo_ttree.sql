
\set ON_ERROR_STOP on
\pset pager off
CREATE EXTENSION IF NOT EXISTS ttree;

DROP TABLE IF EXISTS inventario;
CREATE TABLE inventario (id serial PRIMARY KEY, stock int, nombre text);

\echo '--- 1. Cargar 50 000 filas y crear el índice (camino ambuild) ---'
INSERT INTO inventario (stock, nombre)
SELECT (random() * 1000)::int, 'producto_' || g FROM generate_series(1, 50000) g;

CREATE INDEX inventario_stock_tt ON inventario USING ttree (stock);
SELECT ttree_check('inventario_stock_tt') AS estado;
SELECT pg_size_pretty(pg_relation_size('inventario_stock_tt')) AS tamano_indice;

\echo '--- 2. Insertar más filas con el índice ya creado (camino aminsert) ---'
INSERT INTO inventario (stock, nombre)
SELECT (random() * 1000)::int, 'nuevo_' || g FROM generate_series(1, 5000) g;
SELECT ttree_check('inventario_stock_tt') AS estado;

\echo '--- 3. Búsqueda exacta: el índice devuelve TIDs (reemplazan offset/plato) ---'
SELECT * FROM ttree_lookup('inventario_stock_tt', 500, 500) LIMIT 5;

\echo '--- 4. Los TIDs apuntan a las filas correctas del heap ---'
SELECT l.key, l.tid, i.id, i.nombre
FROM ttree_lookup('inventario_stock_tt', 500, 500) l
JOIN inventario i ON i.ctid = l.tid
ORDER BY i.id LIMIT 5;

\echo '--- 5. Búsqueda por rango: índice vs recorrido secuencial (deben coincidir) ---'
SELECT (SELECT count(*) FROM ttree_lookup('inventario_stock_tt', 100, 120)) AS por_indice,
       (SELECT count(*) FROM inventario WHERE stock BETWEEN 100 AND 120)     AS por_heap;

\echo '--- 6. Estructura del árbol (primeras entradas, en orden) ---'
SELECT blk, nkeys, height, left_blk, right_blk, pos, key, tid
FROM ttree_dump('inventario_stock_tt') LIMIT 8;

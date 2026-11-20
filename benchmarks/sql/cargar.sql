\set ON_ERROR_STOP on
SELECT CASE WHEN :'ds' IN ('d4', 'd5') THEN 'varchar(64)' ELSE 'int' END AS tipo,
       CASE WHEN :'ds' = 'd3' THEN 'd2' ELSE :'ds' END AS origen \gset

SELECT format('d_%s_%s', :'origen', :n) AS base \gset
SELECT NOT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = 'bench' AND tablename = :'base') AS falta_base \gset
\if :falta_base
CREATE TABLE bench.:"base" (ord int, k :tipo);
COPY bench.:"base" FROM :'archivo_base' WITH (FORMAT csv);
\endif

DROP TABLE IF EXISTS bench.:"w1", bench.:"w2", bench.:"w3", bench.:"w4";
CREATE TABLE bench.:"w1" (op int, a :tipo, b :tipo);
CREATE TABLE bench.:"w2" (op int, a :tipo, b :tipo);
CREATE TABLE bench.:"w3" (op int, a :tipo, b :tipo);
CREATE TABLE bench.:"w4" (op int, a :tipo, b :tipo);
COPY bench.:"w1" FROM :'archivo_w1' WITH (FORMAT csv);
COPY bench.:"w2" FROM :'archivo_w2' WITH (FORMAT csv);
COPY bench.:"w3" FROM :'archivo_w3' WITH (FORMAT csv);
COPY bench.:"w4" FROM :'archivo_w4' WITH (FORMAT csv);
VACUUM ANALYZE bench.:"base";

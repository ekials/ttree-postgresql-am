# Semanas 1–5: auditoría y consolidación

## Objetivo

Comprobar que lo entregado en la Etapa I (T-Tree como Index Access Method de PostgreSQL 18.6) sigue funcionando antes de construir encima los benchmarks y el escenario distribuido, y corregir los errores que comprometen la corrección de los resultados.

## Qué se revisó

| Componente | Archivo | Resultado |
|---|---|---|
| Registro del AM (`tthandler`) | `src/ttree.c` | Un flag incorrecto (`amoptionalkey`), corregido |
| `ambuild` / `ambuildempty` | `ttbuild`, `tt_bulk`, `ttbuildempty` | Correcto; UNLOGGED se rechaza con error explícito |
| `aminsert` | `ttinsert`, `tt_insert_rec`, `tt_rebalance`, `tt_rot_left/right` | Correcto (orden, duplicados, rotaciones simples y dobles verificadas con `ttree_check`) |
| Escaneo | `ttbeginscan`, `ttrescan`, `ttgettuple`, `ttendscan`, `tt_scan_prepare` | Correcto; no informaba estadísticas de uso, corregido |
| VACUUM | `ttbulkdelete`, `ttvacuumcleanup` | Conteo incorrecto con varias pasadas, corregido |
| Costos | `ttcostestimate` | Usa `genericcostestimate` (limitación conocida) |
| Validación | `ttvalidate` | Devuelve siempre `true` (limitación conocida) |
| Páginas, buffers, WAL | `tt_get_node`, `tt_put_node`, `tt_new_page`, `tt_meta_lock` | Correcto; cada página se registra con GenericXLog |
| Funciones SQL | `ttree_check`, `ttree_dump`, `ttree_lookup` | Correctas |
| Pruebas originales | `tests/validar_tid.sql`, `tests/test_scan.sql` | Pasan (615 consultas sin diferencias contra el heap) |

## Problemas confirmados y corregidos

### P1. `amoptionalkey = true` con valores NULL sin indexar (gravedad alta)

- **Archivo y función:** `src/ttree.c`, `tthandler`.
- **Problema:** el AM no indexa NULL, pero declaraba `amoptionalkey = true`. La documentación de PostgreSQL (*Index Access Method Interface*) exige que un AM con `amoptionalkey = true` indexe los NULL, porque el planner puede usarlo sin ninguna condición sobre la clave. Con un índice parcial (`... WHERE b = 1`) y una consulta que no restringe la columna indexada, el planner eligió un *Index Only Scan* sin claves de búsqueda.
- **Reproducción (código original):**
  ```sql
  CREATE TABLE p (id serial, a int, b int);
  INSERT INTO p (a, b) SELECT CASE WHEN g % 4 = 0 THEN NULL ELSE g END, g % 2 FROM generate_series(1, 2000) g;
  CREATE INDEX p_tt ON p USING ttree (a) WHERE b = 1;
  ANALYZE p; SET enable_seqscan = off; SET enable_bitmapscan = off;
  SELECT count(*) FROM p WHERE b = 1;
  -- ERROR:  no data returned for index-only scan
  ```
  El mismo plan sin claves, en un *Index Scan* que necesita columnas del heap, omitiría las filas con `a IS NULL`. La documentación de PostgreSQL describe esta consecuencia y la prueba R1 la cubre. Con el código original solo se observó directamente el error del index-only scan.
- **Corrección:** `amoptionalkey = false`. El planner solo considera el índice cuando hay una condición indexable sobre la clave, que es justamente el caso que el T-Tree resuelve.
- **Prueba de regresión:** `tests/regression/regresion_am.sql`, bloque R1. Con el código original falla con el error anterior; con la corrección pasa.
- **Diferencia con el informe del parcial:** el Cuadro II del parcial indicaba `amoptionalkey = true` («se permiten consultas sin condición sobre la clave»). El valor correcto para un AM que no indexa NULL es `false`.

### P2. `ttbulkdelete` acumulaba `num_index_tuples` entre pasadas de VACUUM (gravedad media)

- **Archivo y función:** `src/ttree.c`, `ttbulkdelete`.
- **Problema:** cuando VACUUM no puede guardar todos los TID muertos en memoria, llama a `ambulkdelete` varias veces, y cada llamada recorre el índice completo. El contador de entradas vivas se sumaba en cada pasada. PostgreSQL usa ese valor para `pg_class.reltuples` del índice, es decir, para las estimaciones del planner.
- **Reproducción:** con 300 000 filas, borrando la mitad y `maintenance_work_mem = 64kB`, VACUUM hizo 37 pasadas y dejó `reltuples` del índice en 8 254 611, cuando quedaban 150 000 filas vivas.
- **Corrección:** reiniciar `stats->num_index_tuples = 0` al comienzo de cada pasada (es lo mismo que hace el B-tree nativo en `btvacuumscan`).
- **Prueba de regresión:** bloque R2. Tras VACUUM en varias pasadas, `reltuples` del índice debe coincidir con el del heap; con la corrección queda 40000 = 40000.

### P3. El escaneo no informaba sus búsquedas a PostgreSQL (gravedad baja, observabilidad)

- **Archivo y función:** `src/ttree.c`, `tt_scan_prepare`.
- **Problema:** no se llamaba a `pgstat_count_index_scan` ni se incrementaba `scan->instrument->nsearches` (campo nuevo de PostgreSQL 18). Por eso `pg_stat_user_indexes.idx_scan` quedaba siempre en 0 y `EXPLAIN ANALYZE` mostraba `Index Searches: 0`, lo que impedía comprobar el uso del índice en los benchmarks.
- **Corrección:** se añaden ambas llamadas cuando el escaneo recorre el árbol.
- **Prueba:** bloque R5. `EXPLAIN (ANALYZE, BUFFERS)` muestra `Index Scan using r_tx_tt` con `Index Searches: 1`.

## Riesgos técnicos (no son errores de resultado; se documentan)

| Riesgo | Detalle | Mitigación |
|---|---|---|
| WAL de varias páginas no atómico | Una inserción con rotación escribe varias páginas en registros GenericXLog separados. Una caída en mitad de la operación podría dejar el árbol inconsistente. | `ttree_check` lo detecta y `REINDEX` reconstruye. La prueba `tests/integration/reinicio.sh` comprueba la recuperación tras `SIGKILL` entre transacciones, pero no la caída en mitad de una rotación. |
| Escrituras serializadas | La metapágina se bloquea en modo exclusivo durante toda la inserción y VACUUM. | Aceptado por el alcance académico. |
| Escaneo materializado | `ttgettuple` reúne en memoria todos los TID del rango antes de devolver el primero. | Las consultas del benchmark son selectivas. |
| Tombstones sin reciclar | Las entradas borradas por VACUUM se marcan pero no se eliminan, y el índice no se encoge. | `REINDEX`. |
| Funciones de inspección públicas | `ttree_dump` y `ttree_lookup` devuelven claves y TID sin comprobar el privilegio SELECT sobre la tabla. | Uso en entorno de laboratorio; en producción habría que revocarlas de PUBLIC. |
| Costo genérico | `genericcostestimate` no modela la altura log2(N) del árbol binario. | Los benchmarks fuerzan el método de acceso para medir cada estructura. |
| `ttvalidate` mínimo | No verifica la clase de operadores. | La clase `int4_ops` está fija en el script de la extensión. |

## Funcionalidades no implementadas (fuera del alcance)

Index-only scan, bitmap scan, escaneo hacia atrás, `ORDER BY` por el índice, índices multicolumna, UNIQUE, tablas UNLOGGED, tipos distintos de `int4` (incluido VARCHAR) y concurrencia de escritores.

## Verificación ejecutada

| Caso | Dónde | Resultado |
|---|---|---|
| `CREATE EXTENSION`, `CREATE INDEX ... USING ttree` | todas las suites | OK |
| Construcción sobre tabla vacía y poblada | `validar_tid.sql` 1 y 6a | OK |
| Inserciones posteriores, ascendentes y descendentes | `validar_tid.sql` 2–4 | OK, `ttree_check` balanceado |
| Operadores `<`, `<=`, `=`, `>=`, `>`, `BETWEEN`, rangos vacíos | `test_scan.sql`, R3 | 615 consultas y extremos de int4 sin diferencias |
| Duplicados y extremos de INTEGER | R3 | OK |
| NULL (no indexados, `IS NULL` correcto) | `validar_tid.sql` 6b, R1, R3 | OK |
| DELETE + VACUUM, VACUUM en varias pasadas | `validar_tid.sql` 5, R2 | OK |
| REINDEX, TRUNCATE, CREATE INDEX CONCURRENTLY | `validar_tid.sql` 6c, R4 | OK |
| Transacción abortada | R4 | OK |
| Tablas particionadas | prueba manual de auditoría | Index Scan sobre la partición correcta |
| Uso real del índice por el planner | R5 y `test_scan.sql` | `Index Scan using ...` con `Index Searches: 1` |
| Reinicio ordenado y caída abrupta (`SIGKILL`) | `tests/integration/reinicio.sh` | `ttree_check` OK y 0 diferencias contra el heap |
| Rechazos esperados: UNLOGGED, multicolumna, UNIQUE | prueba manual de auditoría | Error explícito |

Comandos:

```bash
./scripts/reset.sh 4
./scripts/test.sh
./tests/integration/reinicio.sh
```

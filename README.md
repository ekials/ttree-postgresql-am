# T-Tree como Index Access Method de PostgreSQL 18.6

Proyecto final de Bases de Datos II (Universidad Católica San Pablo, Grupo 4). Tiene tres partes:

1. Un índice **T-Tree** escrito en C e integrado en PostgreSQL como método de acceso (`CREATE INDEX ... USING ttree`).
2. Una **evaluación de rendimiento** frente al acceso sin índice y al B-tree nativo.
3. Un **escenario distribuido** de tres nodos con fragmentación por rango y por hash, latencias simuladas, replicación lógica y prueba de caída de un nodo.

## Requisitos

- Linux o WSL 2 con **Docker Engine** y el plugin **Docker Compose v2**. Se probó con Docker 29.1 sobre Ubuntu en WSL 2, con 8 CPU y 7,5 GiB.
- Unos 15 GB libres en disco.
- No hace falta instalar PostgreSQL ni Python: el servidor (`postgres:18.6`) y las herramientas (`python:3.12.8-slim` con `matplotlib 3.9.2`) corren en contenedores.

## Estructura

| Ruta | Contenido |
|---|---|
| `src/ttree.c`, `sql/ttree--1.0.sql`, `ttree.control`, `Makefile` | Extensión T-Tree (C, PGXS) |
| `Dockerfile`, `docker-compose.yml`, `docker/initdb/` | Servidor único para pruebas y benchmarks |
| `tests/` | Pruebas SQL originales, `regression/` y `integration/` |
| `scripts/` | `reset.sh`, `test.sh`, `demo.sh`, `psql.sh` |
| `python/` | Prototipo en Python del T-Tree (semanas 2–3) |
| `benchmarks/` | Generadores, workloads, SQL de medición, runners, resultados y gráficos (semana 6) |
| `distributed/` | Tres nodos, SQL de fragmentación y replicación, workloads, scripts y resultados (semanas 7–9) |
| `docs/` | Documentación por semana e informe final |

## 1. Construir el entorno e instalar la extensión

```bash
./scripts/reset.sh 4      # borra el volumen, compila con TT_MAX_KEYS=4 y levanta PostgreSQL
./scripts/reset.sh 500    # igual, con nodos de 500 claves
```

La extensión se crea sola al iniciar la base `bd2` (`docker/initdb/01_ttree.sql`). Uso básico:

```sql
CREATE TABLE t (k int);
CREATE INDEX t_tt ON t USING ttree (k);
SELECT ttree_check('t_tt');                 -- integridad y balanceo
SELECT * FROM ttree_dump('t_tt') LIMIT 10;  -- nodos y entradas
SELECT * FROM ttree_lookup('t_tt', 10, 20); -- búsqueda directa en el árbol
```

## 2. Pruebas del T-Tree

```bash
./scripts/test.sh                   # validar_tid.sql, test_scan.sql y regression/regresion_am.sql
./tests/integration/reinicio.sh     # reinicio ordenado y caída abrupta (SIGKILL) con recuperación por WAL
./scripts/demo.sh                   # demostración breve
```

Cada suite termina con `==== ... OK ====` y código de salida 0. Si hay alguna diferencia contra el heap o falla `ttree_check`, la suite se detiene con error.

## 3. Datasets y benchmarks (semana 6)

```bash
./scripts/reset.sh 4
./benchmarks/runners/preparar_datos.sh            # D1, D2, D4 y D5 más los workloads W1–W4 (D3 reutiliza D2)
TT_MAX_KEYS=4 ./benchmarks/runners/run_bench.sh   # sin_indice, btree y ttree; D1–D3; 100k, 500k y 1M; 5 repeticiones
```

Variables del runner: `METODOS`, `DATASETS`, `TAMANOS`, `REPS` y `REP_INICIO` (para reanudar desde una repetición). Para reproducir todas las mediciones del informe (TT_MAX_KEYS=500, TT_MAX_KEYS=4, sin índice y VARCHAR), en unas 10 horas, la mayor parte para el caso sin índice, con el equipo conectado a la corriente y sin suspensión:

```bash
./benchmarks/runners/run_all.sh
```

Los datos se generan en el volumen Docker `benchdata`, no en el repositorio. Sus sumas SHA-256 quedan en `benchmarks/results/<config>/manifiesto_entradas.txt`.

Para generar tablas y gráficos:

```bash
docker compose --profile tools run --rm tools python benchmarks/plots/analizar.py
```

Esto produce `benchmarks/results/resumen.md`, `benchmarks/results/resumen.csv` y `benchmarks/plots/*.png`.

## 4. Entorno distribuido (semanas 7–9)

Detén primero el servidor único (`docker compose stop db`) para no mezclar cargas.

```bash
cd distributed
./scripts/levantar.sh               # 3 nodos, esquema, replicación, carga de 1M de pedidos, índices, verificación y latencias
./scripts/validar_latencias.sh      # matriz de ping A–B 20 ms, A–C 40 ms, B–C 25 ms
./scripts/consultas.sh              # consultas distribuidas de ejemplo en ambas estrategias
```

Consultas manuales desde el coordinador A:

```bash
docker compose exec nodo_a psql -U postgres -d dist
```

```sql
SET search_path = g_rango, public;   -- o g_hash
EXPLAIN (ANALYZE, VERBOSE) SELECT count(*) FROM pedidos WHERE id_cliente BETWEEN 150000 AND 150999;
```

## 5. Reproducir los experimentos distribuidos

```bash
cd distributed
./scripts/experimentos.sh           # consultas Q1–Q6 y pgbench 70/30 (unos 35 min)
./scripts/caida_nodo.sh rango       # caída de C, conmutación manual a la réplica y retorno
./scripts/caida_nodo.sh hash
./scripts/analizar.sh               # results/resumen.md y results/graficos/*.png
```

## 6. Detener y limpiar

```bash
(cd distributed && ./scripts/detener.sh)            # detiene los nodos y conserva los datos
(cd distributed && ./scripts/detener.sh --limpiar)  # elimina también los volúmenes
docker compose down                                 # servidor único
docker compose down -v                              # además borra pgdata y benchdata
```

## Documentación

- [Semanas 1–5: auditoría y consolidación](docs/semana_01_05/auditoria.md)
- [Semana 6: evaluación de rendimiento](docs/semana_06/README.md)
- [Semana 7: diseño distribuido](docs/semana_07/README.md)
- [Semana 8: implementación distribuida](docs/semana_08/README.md)
- [Semana 9: experimentos distribuidos](docs/semana_09/README.md)
- [Semana 10: informe final y validación](docs/semana_10/README.md)

## Fuentes y código reutilizado

- T. J. Lehman y M. J. Carey, «A study of index structures for main memory database management systems», VLDB 1986: definición del T-Tree.
- `contrib/bloom` de PostgreSQL: guía de la estructura mínima de un Index AM (registro del handler y GenericXLog). La lógica del T-Tree es del grupo.
- Documentación oficial de PostgreSQL: Index Access Method Interface, Generic WAL, `postgres_fdw`, replicación lógica y pgbench.
- Repositorio [ekials/Simulaci-n-Disco](https://github.com/ekials/Simulaci-n-Disco): punto de partida del prototipo Python (`avl.py`, `disco.py`, `lector2.py` e `interfaz.py`).
- Imágenes oficiales de Docker `postgres:18.6` y `python:3.12.8-slim`; biblioteca `matplotlib`, usada solo para los gráficos.
- Se usaron asistentes de IA como apoyo en la implementación, las pruebas y la documentación, tal como se declara en el informe.

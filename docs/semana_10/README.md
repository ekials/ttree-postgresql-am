# Semana 10: entrega final y validación

## Objetivo

Cerrar el proyecto con:
- el informe final;
- el README de reproducción;
- una validación desde cero de todo lo entregado, con evidencia guardada en el repositorio.

## Entregables

| Archivo | Contenido |
|---|---|
| `docs/semana_10/informe_final.md` | Informe final: fundamentos, diseño, integración, metodología, resultados locales y distribuidos, discusión, limitaciones, conclusiones y referencias |
| `README.md` | Requisitos, estructura y comandos para construir, probar, medir y reproducir los experimentos |
| `docs/semana_10/evidencia/` | Salida de la validación final |

## Corrección hecha durante la validación

Al reconstruir las imágenes se comprobó con `SELECT version()` y `dpkg -l` que el servidor era **PostgreSQL 18.7**, aunque los Dockerfile partían de `postgres:18.6`.

- **Causa:** `apt-get install postgresql-server-dev-18`, sin versión fija, instalaba el paquete de desarrollo 18.7 y actualizaba el servidor por dependencia.
- **Corrección:** se fijó el paquete a la versión de la imagen, `postgresql-server-dev-${PG_MAJOR}=${PG_VERSION}`, en `Dockerfile` y en `distributed/docker/Dockerfile` (commit `fijar version del servidor en las imagenes docker`).
- **Situación final:** el servidor y las cabeceras de compilación quedan en 18.6. `libpq` pasa a 19.0, porque el repositorio ya no publica `libpq-dev` 18.6; es solo la biblioteca cliente y es compatible con un servidor 18.
- **Alcance:** los benchmarks de la semana 6 y los experimentos de las semanas 8 y 9 se midieron sobre 18.7 y no se repitieron. Se declara en sus documentos y en el informe.

## Validación ejecutada

Ejecutada el 20/11/2026 sobre Windows 11 + WSL 2 (8 CPU, 7,5 GiB, Docker 29.1).

### Servidor único (`evidencia/validacion_servidor_unico.txt`)

Para `TT_MAX_KEYS=4` y `TT_MAX_KEYS=500`: `docker compose build --no-cache db`, `./scripts/reset.sh`, `./scripts/test.sh` y `./tests/integration/reinicio.sh`.

| Comprobación | Resultado con 4 y 500 |
|---|---|
| Imagen reconstruida sin caché | OK |
| Versión del servidor | `PostgreSQL 18.6 (Debian 18.6-1.pgdg13+2)` |
| Compilación de la extensión | Sin errores ni advertencias del compilador |
| `tests/validar_tid.sql` (pruebas originales) | `==== TODAS LAS PRUEBAS OK ====` |
| `tests/test_scan.sql` (pruebas originales) | 615 consultas comparadas, 0 diferencias; 0 diferencias tras VACUUM |
| `tests/regression/regresion_am.sql` (R1–R5) | `==== REGRESION OK ====`; R2 `reltuples` 40000 = 40000 |
| `tests/integration/reinicio.sh` | 0 diferencias antes, tras el reinicio y tras `SIGKILL` con recuperación por WAL |
| Integridad (`ttree_check`) | OK en todas las suites |

### Benchmarks obligatorios (semana 6)

No se volvieron a ejecutar: la serie completa tarda unas 10 horas. Se verificaron los resultados registrados:

| Comprobación | Resultado |
|---|---|
| Tres tamaños (100k, 500k y 1M) en D1–D5 | Presentes en `benchmarks/results/resumen.md` |
| Cinco repeticiones por combinación | 5 en cada combinación de dataset, tamaño y método (`resultados.csv`) |
| Mismo resultado en todos los métodos | 45 de 45 combinaciones sin diferencias |
| Integridad del T-Tree tras W3 | `ttree_check` OK en 90 de 90 índices |
| `TT_MAX_KEYS` sin mezclar | Verificado por el runner con `ttree_dump`; resultados en `tt4/` y `tt500/` |
| Reproducibilidad de las entradas | Semillas fijas y SHA-256 en `manifiesto_entradas.txt` |

### Entorno distribuido (`evidencia/validacion_distribuida.txt` y `evidencia/distribuido/`)

Desde cero: `./scripts/detener.sh --limpiar`, `docker compose build --no-cache nodo_a`, `./scripts/levantar.sh`, `./scripts/validar_latencias.sh`, `./scripts/consultas.sh` y `./scripts/caida_nodo.sh` para rango y hash, con la caída a los 20 s y la conmutación a los 40 s.

| Comprobación | Resultado |
|---|---|
| Versión de los tres nodos | PostgreSQL 18.6 en A, B y C |
| Carga, replicación inicial y fragmentación | Réplicas sincronizadas; `VERIFICACION OK` en las dos estrategias |
| Latencias (RTT promedio con ping) | A→B 20,4 · A→C 40,5 · B→A 20,5 · B→C 26,8 (mín. 25,2; un paquete de 39 ms) · C→A 40,5 · C→B 25,5 ms |
| Consultas distribuidas Q1–Q6 (`consultas.sh`, mediana de 3 repeticiones, B-tree, con latencia) | Sin errores. Reproducen la semana 9: Q1 cliente en C 205 / 204 ms (semana 9: 203 / 204), Q2 172,7 / 371,7 ms (166,6 / 371,8), Q4 506 / 510 ms (500 / 498), Q3 28,4 / 28,3 s (28,0 / 27,8), con los mismos bytes recibidos en Q2 (61 077 / 40 662) |

Prueba de caída de C. Operaciones correctas y fallidas por fase:

| Consulta | Antes | C caído | Conmutado a la réplica | Tras el retorno |
|---|---|---|---|---|
| Lectura local en A (rango / hash) | 17 / 10 OK | 47 / 51 OK | 183 / 138 OK | 13 / 25 OK |
| Lectura de un cliente de C | 16 OK, 1 error* / 9 OK, 1 error* | 46 / 50 errores, 1 OK* | 183 / 138 OK | 13 / 25 OK |
| Lectura global | 15 OK, 2 errores* / 9 OK, 1 error* | 46 / 50 errores, 1 OK* | 183 / 138 OK | 13 / 25 OK |
| Escritura en un cliente de C | 15 OK, 1 error* / 9 OK, 1 error* | 47 / 50 errores | 183 / 138 rechazadas (réplica de solo lectura)* | 13 / 25 OK |

\* Operaciones que estaban en curso en el instante del cambio de fase: la sonda registra la hora de inicio de cada operación.

Tras la recuperación, los 9 pares primario/réplica coinciden en cada estrategia (`caida_replicas_*.txt`).

Los archivos de `distributed/results/` se restauraron después de esta validación. Siguen siendo los de la corrida documentada en las semanas 8 y 9; la salida nueva está solo en `evidencia/distribuido/`.

### Revisión de documentación

- Se comprobaron todos los enlaces relativos de los archivos Markdown (`README.md`, `docs/*`, `benchmarks/results/resumen.md` y `distributed/results/resumen.md`): no hay ninguno roto.
- Las rutas de archivos citadas en la documentación existen.
- Todas las cifras de los documentos provienen de `benchmarks/results/`, `distributed/results/` o de la evidencia de esta carpeta.

## Comandos

```bash
./scripts/reset.sh 4 && ./scripts/test.sh && ./tests/integration/reinicio.sh
./scripts/reset.sh 500 && ./scripts/test.sh && ./tests/integration/reinicio.sh
docker compose stop db
cd distributed && ./scripts/detener.sh --limpiar && ./scripts/levantar.sh
./scripts/validar_latencias.sh && ./scripts/consultas.sh
T_CAIDA=20 T_CONMUTA=40 T_RETORNO=70 T_TOTAL=120 ./scripts/caida_nodo.sh rango
```

## Limitaciones

- Los benchmarks y los experimentos distribuidos no se repitieron sobre 18.6 (ver arriba).
- En la validación final, la caída de nodo se ejecutó una vez por estrategia y pgbench no se repitió.
- En el enlace B→C, un paquete de 10 tardó 39 ms, lo que subió el promedio a 26,8 ms. El mínimo fue de 25,2 ms y el sentido contrario (C→B) promedió 25,5 ms.
- El `WARNING: no connection to the server` del registro es esperado: lo emite la sonda cuando se mata el nodo C.

# Semana 8: implementación distribuida

## Objetivo

Implementar el diseño de la semana 7 sobre tres nodos PostgreSQL 18.6 en Docker, con latencias simuladas por par de nodos, consultas distribuidas, replicación real y una prueba de indisponibilidad de un nodo.

## Implementación

### Nodos

`distributed/docker-compose.yml` levanta `nodo_a`, `nodo_b` y `nodo_c` en una red propia (`172.28.0.11`, `.12` y `.13`). Usan una imagen común (`distributed/docker/Dockerfile`) que parte de `postgres:18.6`, compila la extensión T-Tree con `TT_MAX_KEYS=500` e instala `iproute2` (`tc`) e `iputils-ping`. Cada nodo tiene su propio volumen de datos, `wal_level=logical` y `shared_buffers=512MB`.

### Latencias por par

`distributed/scripts/latencias.sh` aplica en cada contenedor una disciplina `prio` con una banda `netem` por cada destino, seleccionada con un filtro `u32` por IP de destino. El resto del tráfico, incluido el que va al propio nodo, no se retrasa.

Las latencias pedidas se interpretan como **tiempo de ida y vuelta (RTT)**. Cada extremo retrasa la mitad en su salida:

| Par | RTT objetivo | Retardo de salida en cada extremo | RTT medido con ping (mín / prom / máx, 10 paquetes) |
|---|---|---|---|
| A–B | 20 ms | 10 ms | A→B 20,19 / 20,67 / 22,43 · B→A 20,21 / 20,42 / 21,38 |
| A–C | 40 ms | 20 ms | A→C 40,22 / 40,50 / 41,05 · C→A 40,21 / 40,72 / 42,15 |
| B–C | 25 ms | 12,5 ms | B→C 25,22 / 25,49 / 26,90 · C→B 25,33 / 25,68 / 27,05 |

La validación (`validar_latencias.sh`) guarda la matriz de ping y las reglas `tc` activas en `distributed/results/latencias_validacion.txt`. Como cada par tiene su propio retardo, el mecanismo representa latencias entre pares y no una latencia global.

### Consultas distribuidas

Se usa `postgres_fdw` con particionamiento declarativo. En cada nodo hay tablas globales `g_rango.*` y `g_hash.*`, cuya partición local es una tabla normal y cuyas particiones remotas son tablas foráneas. Opciones de los servidores remotos:

| Opción | Valor | Motivo |
|---|---|---|
| `fetch_size` | 1000 | Filas por ida y vuelta al leer |
| `batch_size` | 1000 | Filas por ida y vuelta al insertar |
| `connect_timeout` | 3 s | Fallo rápido al conectar con un nodo caído |
| `tcp_user_timeout` | 3000 ms | Sin este valor, una conexión abierta hacia un nodo caído quedó bloqueada unos 70 s en la primera prueba |

### Replicación

Es replicación lógica nativa y continua: `productos` de A hacia B y C, y cada fragmento hacia el nodo siguiente (A→B, B→C, C→A). Las réplicas rechazan escrituras de sesiones normales mediante un *trigger*.

### Indisponibilidad y conmutación

`dist.conmutar(estrategia, nodo, usar_replica)` desacopla en el coordinador A las particiones foráneas del nodo caído y acopla en su lugar la réplica local, que queda en solo lectura. También hace la operación inversa. La conmutación **es manual**: el sistema no detecta fallos ni conmuta solo.

## Archivos relevantes

| Archivo | Función |
|---|---|
| `distributed/docker-compose.yml`, `distributed/docker/Dockerfile` | Tres nodos |
| `distributed/scripts/levantar.sh` | Construye, crea el esquema, replica, carga, indexa, verifica y aplica latencias |
| `distributed/scripts/latencias.sh`, `validar_latencias.sh` | Latencias por par y su validación |
| `distributed/sql/07_rutinas.sql` | Medición (`dist.medir`), sonda de disponibilidad y conmutación |
| `distributed/sql/08_consultas.sql`, `distributed/scripts/consultas.sh` | Catálogo de consultas Q1–Q6 |
| `distributed/workloads/*.sql` | Carga mixta de pgbench (35 % lectura por cliente, 35 % lectura por rango, 30 % escritura) |
| `distributed/scripts/caida_nodo.sh` | Escenario de caída de C |
| `distributed/scripts/detener.sh` | Detiene el entorno (`--limpiar` borra los volúmenes) |

## Comandos

```bash
cd distributed
./scripts/levantar.sh              # entorno completo; INDICE=ttree para crear T-Tree en lugar de B-tree
./scripts/consultas.sh             # consultas distribuidas de ejemplo en ambas estrategias
./scripts/caida_nodo.sh rango      # caída abrupta de C, conmutación y retorno
./scripts/latencias.sh off|on      # quitar o reponer las latencias
./scripts/detener.sh [--limpiar]
```

## Pruebas y resultados

- **Fragmentación** (`results/verificacion_fragmentos.txt`): las 20 comprobaciones de completitud, disyunción, reconstrucción, predicado y fragmentación derivada dan `VERIFICACION OK`. Reparto en rango: 334 256 / 331 767 / 333 977 pedidos; en hash: 334 796 / 332 827 / 332 377.
- **Replicación inicial**: los 18 pares primario/réplica tienen el mismo número de filas antes de empezar las pruebas.
- **Consultas** (mediana de 20 repeticiones, coordinador en A, índice B-tree):
  - Q1, cliente local: 0,23 ms.
  - Q1, cliente en B: 102,5 ms, unas 5 idas y vueltas de 20 ms: inicio de la transacción remota, declaración del cursor, lectura, cierre y *commit*.
  - Q1, cliente en C: 203 ms.
- **Caída de C** (`results/caida_*`), sonda cada 0,2 s desde A durante 120 s: caída abrupta (`SIGKILL`) a los 20 s, conmutación a los 40 s, retorno a los 70 s.

| Consulta (estrategia rango) | Antes | C caído, sin conmutar | Conmutado a réplica | Tras el retorno |
|---|---|---|---|---|
| Lectura local en A | 16 OK | 42 OK | 121 OK | 30 OK |
| Lectura de un cliente de C | 16 OK (284 ms) | 42 errores | 121 OK (0,2 ms, réplica local) | 30 OK (284 ms) |
| Lectura global (todos los nodos) | 15 OK, 1 error* | 41 errores, 1 OK* | 121 OK (143 ms) | 30 OK (428 ms) |
| Escritura en un cliente de C | 15 OK, 1 error* | 41 errores | 121 rechazadas (réplica de solo lectura) | 30 OK |

\* Operaciones que estaban en curso justo en el instante de la caída.

La estrategia hash se comporta igual (9 / 43 / 122 / 31 operaciones de lectura local por fase, con el mismo patrón de errores). Tras la recuperación por WAL de C, las suscripciones se reanudan solas y los nueve pares primario/réplica vuelven a coincidir en ambas estrategias.

## Limitaciones

- Los tres nodos comparten la misma máquina física (8 CPU, 7,5 GiB): la latencia es simulada y el ancho de banda no se limita.
- La conmutación es manual y solo se configuró en el coordinador A. En B no se conmuta.
- Durante la conmutación, el fragmento del nodo caído es de solo lectura. No hay elección de un nuevo primario ni reconciliación de escrituras.
- Las transacciones que escriben en varios nodos usan el *commit* de `postgres_fdw`, que no es atómico entre nodos (no hay *two-phase commit*).
- La replicación lógica es asíncrona: una lectura en la réplica puede no ver las últimas escrituras del primario.
- Las mediciones de esta semana se tomaron con los nodos en PostgreSQL **18.7**, no 18.6. `apt-get install postgresql-server-dev-18` sin versión fija actualizaba el servidor de la imagen base. Se corrigió en la semana 10 fijando el paquete a `${PG_VERSION}`, y la puesta en marcha, la verificación, las latencias y la caída de nodo se repitieron sobre 18.6 (`docs/semana_10/README.md`).

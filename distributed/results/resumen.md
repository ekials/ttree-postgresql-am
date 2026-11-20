# Resultados distribuidos (semanas 8 y 9)

Generado por `distributed/scripts/analizar_dist.py` a partir de los archivos de `distributed/results/`.

## Latencia por consulta (mediana en ms, coordinador en el nodo A)

| consulta | latencia de red | rango btree | rango ttree | hash btree | hash ttree | bytes recibidos por A (rango / hash, btree) |
|---|---|---|---|---|---|---|
| q1_cliente_local_a | con | 0.23 | 0.21 | 0.24 | 0.22 | 0 / 0 |
| q1_cliente_local_a | sin | 0.23 | 0.21 | 0.27 | 0.24 | 315 / 315 |
| q1_cliente_remoto_b | con | 102.52 | 102.72 | 102.17 | 102.36 | 940 / 1237 |
| q1_cliente_remoto_b | sin | 0.63 | 0.57 | 0.71 | 0.64 | 940 / 922 |
| q1_cliente_remoto_c | con | 203.08 | 203.55 | 203.53 | 202.90 | 1480 / 999 |
| q1_cliente_remoto_c | sin | 0.64 | 0.59 | 0.62 | 0.62 | 1480 / 999 |
| q2_rango_1000_clientes | con | 166.61 | 173.40 | 371.75 | 370.54 | 61077 / 40662 |
| q2_rango_1000_clientes | sin | 3.06 | 10.59 | 4.34 | 3.84 | 60615 / 40134 |
| q3_agregado_global_region | con | 27973.54 | 27856.68 | 27793.93 | 27656.44 | 24463059 / 23852268 |
| q3_agregado_global_region | sin | 529.93 | 656.41 | 567.48 | 624.87 | 24176044 / 23591677 |
| q4_transferencia_semana | con | 500.16 | 497.64 | 497.73 | 497.69 | 423903 / 422502 |
| q4_transferencia_semana | sin | 9.49 | 10.01 | 9.79 | 10.11 | 421791 / 420522 |
| q5_join_productos_replicados | con | 330.18 | 331.13 | 371.34 | 370.55 | 104294 / 71116 |
| q5_join_productos_replicados | sin | 3.96 | 4.30 | 4.82 | 5.00 | 103634 / 70687 |
| q6_insercion_local_a | con | 0.70 | 0.70 | 1.32 | 0.74 | 0 / 0 |
| q6_insercion_local_a | sin | 1.43 | 0.70 | 1.71 | 0.78 | 210 / 210 |
| q6_insercion_remota_c | con | 203.68 | 204.70 | 204.77 | 204.26 | 1469 / 1467 |
| q6_insercion_remota_c | sin | 1.42 | 1.21 | 1.39 | 1.36 | 1209 / 1207 |

## Carga mixta 70 % lecturas / 30 % escrituras (pgbench, 4 clientes en A, 60 s)

| índice | estrategia | acceso | tps | transacciones | fallidas | p50 cliente | p50 rango | p50 escritura | p95 rango | KB de red por transacción |
|---|---|---|---|---|---|---|---|---|---|---|
| btree | hash | uniforme | 20.7 | 1245 | 0 | 101.9 | 304.8 | 164.6 | 307.6 | 6.9 |
| btree | rango | uniforme | 32.1 | 1932 | 0 | 102.1 | 102.7 | 166.4 | 203.0 | 5.6 |
| btree | hash | concentrado en A (Zipf) | 19.9 | 1198 | 0 | 101.9 | 304.4 | 165.4 | 306.0 | 7.1 |
| btree | rango | concentrado en A (Zipf) | 512.8 | 30927 | 0 | 0.2 | 0.5 | 1.5 | 1.5 | 1.4 |
| btree | hash | concentrado en C (Zipf) | 22.2 | 1338 | 0 | 101.6 | 304.0 | 164.0 | 305.6 | 5.4 |
| btree | rango | concentrado en C (Zipf) | 16.8 | 1013 | 0 | 202.0 | 202.2 | 324.9 | 203.1 | 6.0 |
| ttree | hash | uniforme | 20.6 | 1237 | 0 | 102.1 | 304.3 | 166.1 | 305.7 | 6.8 |
| ttree | rango | uniforme | 30.7 | 1851 | 0 | 101.8 | 102.3 | 166.2 | 203.0 | 5.5 |
| ttree | hash | concentrado en A (Zipf) | 20.4 | 1229 | 0 | 101.8 | 304.2 | 165.0 | 305.3 | 7.7 |
| ttree | rango | concentrado en A (Zipf) | 457.0 | 27494 | 0 | 0.2 | 0.8 | 1.5 | 13.5 | 1.4 |
| ttree | hash | concentrado en C (Zipf) | 21.6 | 1301 | 0 | 101.6 | 304.1 | 164.4 | 305.9 | 5.8 |
| ttree | rango | concentrado en C (Zipf) | 16.0 | 964 | 0 | 202.0 | 202.3 | 325.3 | 203.4 | 6.8 |

Proporción real de escrituras en las corridas: entre 30.2 % y 31.6 % de las transacciones.

## Retraso de la replicación lógica durante la carga mixta (`pg_stat_replication.replay_lag`)

| estrategia de la carga | suscripción | muestras | mediana ms | p95 ms | máximo ms |
|---|---|---|---|---|---|
| hash | sub_frag_a | 142 | 20.3 | 22.3 | 220.6 |
| hash | sub_frag_b | 141 | 25.3 | 29.0 | 249.3 |
| hash | sub_frag_c | 142 | 40.3 | 42.7 | 240.6 |
| hash | sub_ref_b | 142 | 20.3 | 20.4 | 21.8 |
| hash | sub_ref_c | 142 | 40.3 | 40.4 | 41.4 |
| rango | sub_frag_a | 148 | 20.3 | 22.4 | 25.2 |
| rango | sub_frag_b | 143 | 25.4 | 225.5 | 427.4 |
| rango | sub_frag_c | 148 | 40.4 | 43.5 | 56.4 |
| rango | sub_ref_b | 148 | 20.3 | 20.4 | 21.2 |
| rango | sub_ref_c | 148 | 40.3 | 40.5 | 42.9 |

## Caída del nodo C, estrategia hash

| consulta | fase | correctas | con error | ms mediana (correctas) |
|---|---|---|---|---|
| escritura_nodo_c | antes de la caída | 8 | 1 | 294.3 |
| escritura_nodo_c | caído, sin conmutar | 0 | 42 | - |
| escritura_nodo_c | conmutado a réplica | 0 | 122 | - |
| escritura_nodo_c | tras el retorno | 31 | 0 | 285.6 |
| lectura_global | antes de la caída | 8 | 1 | 427.9 |
| lectura_global | caído, sin conmutar | 1 | 42 | 844.9 |
| lectura_global | conmutado a réplica | 122 | 0 | 143.2 |
| lectura_global | tras el retorno | 31 | 0 | 428.0 |
| lectura_local_a | antes de la caída | 9 | 0 | 0.3 |
| lectura_local_a | caído, sin conmutar | 43 | 0 | 0.3 |
| lectura_local_a | conmutado a réplica | 122 | 0 | 0.3 |
| lectura_local_a | tras el retorno | 31 | 0 | 0.2 |
| lectura_nodo_c | antes de la caída | 9 | 0 | 284.2 |
| lectura_nodo_c | caído, sin conmutar | 0 | 43 | - |
| lectura_nodo_c | conmutado a réplica | 122 | 0 | 0.1 |
| lectura_nodo_c | tras el retorno | 31 | 0 | 284.3 |

Mensajes de error observados:

- `could not connect to server "nodo_c"`
- `la tabla hash.pedidos_c es una replica de solo lectura`
- `server closed the connection unexpectedly
	This probably means the server terminated abnormally
	before or while processing the request.
invalid socket`

## Caída del nodo C, estrategia rango

| consulta | fase | correctas | con error | ms mediana (correctas) |
|---|---|---|---|---|
| escritura_nodo_c | antes de la caída | 15 | 1 | 285.8 |
| escritura_nodo_c | caído, sin conmutar | 0 | 41 | - |
| escritura_nodo_c | conmutado a réplica | 0 | 121 | - |
| escritura_nodo_c | tras el retorno | 30 | 0 | 285.9 |
| lectura_global | antes de la caída | 15 | 1 | 427.7 |
| lectura_global | caído, sin conmutar | 1 | 41 | 798.4 |
| lectura_global | conmutado a réplica | 121 | 0 | 143.2 |
| lectura_global | tras el retorno | 30 | 0 | 427.6 |
| lectura_local_a | antes de la caída | 16 | 0 | 0.3 |
| lectura_local_a | caído, sin conmutar | 42 | 0 | 0.3 |
| lectura_local_a | conmutado a réplica | 121 | 0 | 0.3 |
| lectura_local_a | tras el retorno | 30 | 0 | 0.3 |
| lectura_nodo_c | antes de la caída | 16 | 0 | 284.3 |
| lectura_nodo_c | caído, sin conmutar | 0 | 42 | - |
| lectura_nodo_c | conmutado a réplica | 121 | 0 | 0.2 |
| lectura_nodo_c | tras el retorno | 30 | 0 | 283.9 |

Mensajes de error observados:

- `could not connect to server "nodo_c"`
- `la tabla rango.pedidos_c es una replica de solo lectura`


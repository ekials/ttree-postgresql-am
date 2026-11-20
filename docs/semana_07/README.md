# Semana 7: diseño distribuido

## Objetivo

Diseñar un esquema relacional de al menos cuatro tablas, con una relación principal de 1 000 000 de filas, y dos estrategias de fragmentación horizontal que se puedan comparar experimentalmente sobre tres nodos PostgreSQL (A, B y C). El diseño fija la asignación, la replicación, la integridad referencial y el uso de los índices B-tree y T-Tree.

## Esquema

| Tabla | Filas | Clave | Relaciones |
|---|---|---|---|
| `clientes` | 300 000 | `id_cliente int` | — |
| `productos` | 5 000 | `id_producto int` | — |
| `pedidos` | 1 000 000 (relación principal) | `id_pedido bigint` | `id_cliente → clientes` |
| `detalle_pedido` (`detalle`) | ≈ 2 000 000 (1 a 3 líneas por pedido) | `(id_pedido, linea)` | `id_pedido → pedidos`, `id_producto → productos` |

`detalle` incluye además `id_cliente`, copiado del pedido. Esa columna redundante permite la fragmentación derivada: cada línea de detalle queda en el mismo nodo que su pedido y su cliente.

Los datos se generan de forma determinista en el nodo A (`setseed`, `distributed/sql/02_carga.sql` y `02_productos.sql`) y se distribuyen insertando en las tablas globales, que enrutan cada fila a su fragmento.

## Clave de fragmentación: `id_cliente`

Se eligió `id_cliente` por cuatro razones:

1. La mayoría de las operaciones de una tienda son por cliente: historial de pedidos, detalle de un pedido, registro de una compra. Fragmentar `clientes`, `pedidos` y `detalle` por la misma clave deja cada pedido junto a su cliente y su detalle, así que esas consultas y sus *joins* se resuelven en un solo nodo.
2. Las claves foráneas `pedidos → clientes` y `detalle → pedidos` quedan dentro de cada fragmento y se validan localmente, sin restricciones entre nodos.
3. Es `int4`, el tipo que soporta el T-Tree, de modo que se pueden comparar B-tree y T-Tree sobre la columna de acceso real del sistema distribuido.
4. Admite tanto rangos como hash, lo que permite comparar las dos estrategias con exactamente los mismos datos.

## Estrategia A: fragmentación por rangos (`rango`)

| Fragmento | Predicado | Nodo primario | Región |
|---|---|---|---|
| `rango.*_a` | `1 <= id_cliente < 100001` | A | sur (Arequipa, Moquegua, Tacna) |
| `rango.*_b` | `100001 <= id_cliente < 200001` | B | centro (Lima, Ica, Huancayo) |
| `rango.*_c` | `200001 <= id_cliente < 300001` | C | oriente (Cusco, Puno, Abancay) |

Los identificadores de cliente se asignan por bloques regionales, de modo que el rango coincide con la región atendida por cada nodo. Comportamiento esperado:

- Consulta por un cliente: un solo nodo, local si el cliente pertenece al nodo coordinador.
- Consulta por un intervalo de clientes: normalmente un solo nodo.
- Concentración de accesos en clientes de una región: toda la carga recae en un nodo (punto caliente).

## Estrategia B: fragmentación por hash (`hash`)

| Fragmento | Predicado | Nodo primario |
|---|---|---|
| `hash.*_a` | `hash(id_cliente) mod 3 = 0` | A |
| `hash.*_b` | `hash(id_cliente) mod 3 = 1` | B |
| `hash.*_c` | `hash(id_cliente) mod 3 = 2` | C |

Se usa la función de partición hash de PostgreSQL (`PARTITION BY HASH ... MODULUS 3`). Comportamiento esperado:

- Consulta por un cliente: un solo nodo, pero solo un tercio de los clientes es local al coordinador.
- Consulta por un intervalo de clientes: los tres nodos, porque los clientes contiguos se reparten.
- Concentración de accesos: la carga se reparte entre los tres nodos aunque los clientes calientes sean contiguos.

## Corrección de la fragmentación

`distributed/sql/06_verificar.sql` comprueba, para cada estrategia y tabla:

- **Completitud:** el número de filas de la tabla global (unión de los fragmentos) es igual al de los datos generados.
- **Disyunción:** no hay claves repetidas entre fragmentos.
- **Reconstrucción:** `datos generados EXCEPT ALL unión de fragmentos` es vacío.
- **Predicado:** en `rango`, cada fragmento solo contiene clientes de su intervalo.
- **Fragmentación derivada:** en `hash`, cada pedido está en el mismo nodo que su cliente.

## Asignación y replicación

| Nodo | Fragmentos primarios | Réplicas que aloja | Tablas de referencia |
|---|---|---|---|
| A | `rango.*_a`, `hash.*_a` | `rango.*_c`, `hash.*_c` | `productos` (origen) |
| B | `rango.*_b`, `hash.*_b` | `rango.*_a`, `hash.*_a` | `productos` (réplica) |
| C | `rango.*_c`, `hash.*_c` | `rango.*_b`, `hash.*_b` | `productos` (réplica) |

- **`productos`:** replicación total por **replicación lógica nativa y continua** (publicación `pub_ref` en A, suscripciones en B y C). Es una tabla pequeña y de solo lectura para las transacciones, y tenerla en todos los nodos permite validar localmente `detalle → productos`.
- **Fragmentos:** cada fragmento primario se replica de forma continua y asíncrona al nodo siguiente (A→B, B→C, C→A) mediante replicación lógica (`pub_frag_x` y `sub_frag_x`). No es una copia estática: cada inserción en el primario se transmite y se aplica en la réplica.
- **Escrituras:** solo en el primario. Las tablas réplica tienen un *trigger* que rechaza escrituras de sesiones normales. El proceso de replicación no lo dispara, porque se aplica con `session_replication_role = replica`.
- **Conmutación por error:** **manual**, mediante `dist.conmutar` y el script `caida_nodo.sh`. No hay detección ni conmutación automática. Tras la conmutación, el fragmento queda accesible en **modo de solo lectura** desde la réplica.

## Integridad referencial

- `pedidos.id_cliente → clientes` y `detalle.id_pedido → pedidos`: claves foráneas reales dentro de cada fragmento primario, válidas porque las tres tablas se fragmentan por `id_cliente`.
- `detalle.id_producto → productos`: clave foránea local contra la réplica de `productos` de cada nodo.
- Limitaciones: no hay claves foráneas entre nodos ni restricciones globales sobre las tablas particionadas (PostgreSQL no las admite con particiones foráneas). La aplicación de la replicación lógica no valida claves foráneas en el suscriptor.

## Ejecución de consultas distribuidas

Cada nodo define tablas globales particionadas (`g_rango.clientes`, `g_rango.pedidos`, `g_rango.detalle` y sus equivalentes `g_hash.*`). Su partición local es una tabla normal; las otras dos son tablas foráneas de `postgres_fdw` hacia los otros nodos (`remoto.*`). El planner de PostgreSQL:

- Descarta las particiones que no cumplen el predicado de partición (*partition pruning*).
- Envía al nodo remoto los filtros, los *joins* entre tablas foráneas del mismo servidor y las agregaciones parciales (`enable_partitionwise_join` y `enable_partitionwise_aggregate`).
- Recibe las filas en lotes de 1 000 (`fetch_size`) y envía inserciones en lotes de 1 000 (`batch_size`).

## Consultas y costo de comunicación esperado

| Consulta | Estrategia A (rango) | Estrategia B (hash) |
|---|---|---|
| Q1 pedidos y detalle de un cliente | 1 nodo; local o 1 ida y vuelta al remoto | 1 nodo; local con probabilidad 1/3 |
| Q2 intervalo de 1 000 clientes | 1 nodo | 3 nodos |
| Q3 total por región (todos los pedidos) | 3 nodos; agregados parciales, pocas filas | 3 nodos; agregados parciales, pocas filas |
| Q4 pedidos de una semana (≈ 10 000 filas) | 3 nodos; transfiere filas completas | 3 nodos; transfiere filas completas |
| Q5 join `detalle` con `productos` replicados | 1 nodo remoto; transfiere las filas de detalle | 3 nodos |
| Q6 inserción de un pedido | 1 nodo; local o remoto, con *commit* remoto | igual, con ubicación pseudoaleatoria |

El costo de una consulta remota se puede modelar como `RTT × idas_y_vueltas + bytes / ancho_de_banda + costo_local`. Con latencias de 20 a 40 ms, el número de idas y vueltas domina sobre el tiempo de ejecución local de una consulta indexada (decenas de microsegundos).

## Índices B-tree y T-Tree

- `id_cliente` en `pedidos` y `detalle` de cada fragmento (primario y réplica): se compara **B-tree** frente a **T-Tree** (`TT_MAX_KEYS=500`) reconstruyendo el índice en los tres nodos (`05_indices.sql`).
- `fecha`: B-tree en ambos casos, porque el T-Tree no soporta `date`.
- Claves primarias: B-tree (el T-Tree no soporta UNIQUE).

Se espera que la elección del índice influya poco cuando hay latencia de red, porque una búsqueda indexada local cuesta microsegundos frente a decenas de milisegundos de red. La comparación sin latencia aísla el efecto del índice.

## Archivos

- `distributed/sql/01_esquema.sql`: fragmentos, réplicas, servidores remotos y tablas globales.
- `distributed/sql/02_productos.sql`, `02_carga.sql`: generación y distribución de los datos.
- `distributed/sql/03_publicacion.sql`, `04_suscripcion.sql`: replicación lógica.
- `distributed/sql/05_indices.sql`: índices B-tree o T-Tree.
- `distributed/sql/06_verificar.sql`: completitud, disyunción y reconstrucción.

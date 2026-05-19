## Comportamiento de TTL

El TTL de DynamoDB elimina automáticamente los elementos caducados (finalmente consistente, puede persistir hasta 48 horas).

| Tipo de Clave | Valor TTL | Notas |
|----------|-----------|-------|
| `leader` | `failover_time` | Ventana de validez del bloqueo de líder |
| `members/*` | `failover_time * 2` | Latido del miembro (2x para sobrevivir a latidos perdidos) |
| `status` | `failover_time * 2` | Estado del clúster (2x para consistencia con los miembros) |
| `config`, `sync`, `failover`, `history`, `initialize`, `failsafe` | Ninguno | Persistente hasta que se elimine explícitamente |

**Nota:** Los elementos sin TTL persisten indefinidamente. Utilice `patronictl remove` o la limpieza manual para clústeres dados de baja.

## Crear la Tabla

```bash
aws dynamodb create-table \
  --table-name patroni-dynamodb \
  --attribute-definitions \
    AttributeName=cluster_name,AttributeType=S \
    AttributeName=key,AttributeType=S \
  --key-schema \
    AttributeName=cluster_name,KeyType=HASH \
    AttributeName=key,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST
```

Habilitar TTL:

```bash
aws dynamodb update-time-to-live \
  --table-name patroni-dynamodb \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"
```

## Permisos de IAM

Permisos mínimos para el rol de IAM del nodo o credenciales de AWS:

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:Query",
    "dynamodb:BatchWriteItem"
  ],
  "Resource": "arn:aws:dynamodb:REGION:ACCOUNT:table/patroni-dynamodb"
}
```

## Análisis Profundo de la Elección de Líder

Dynatroni implementa un bloqueo distribuido (elección de líder) utilizando las escrituras condicionales de DynamoDB como la primitiva atómica. Esta sección detalla el mecanismo, las garantías y los límites.

### El Mecanismo: Escrituras Condicionales como Semáforos

Las escrituras condicionales de DynamoDB son **atómicas**: la verificación de la condición y la escritura ocurren como una sola operación. Si la condición falla, la escritura es rechazada y el elemento permanece sin cambios. Esto proporciona la base para el bloqueo distribuido sin requerir transacciones distribuidas.

Cada escritura condicional actúa como una operación de **comparación e intercambio (CAS)**:
1. Leer el estado actual (opcional, para la toma de decisiones)
2. Intentar escribir con una condición que codifica el estado esperado
3. Si la condición falla → otro nodo ganó; reintentar o retroceder
4. Si la condición tiene éxito → tenemos el bloqueo

### Operaciones y sus Condiciones

| Operación | Llamada a DynamoDB | Condición | Por qué esta Condición |
|-----------|---------------|-----------|-------------------|
| **Adquirir (nuevo clúster)** | `PutItem` | `attribute_not_exists(cluster_name)` | El elemento no debe existir; el primer escritor gana |
| **Renovar (extender TTL)** | `UpdateItem` | `session = :mine` | Solo el titular actual puede extender |
| **Tomar el control (TTL caducado)** | `PutItem` | `ttl < :now` | El TTL debe seguir caducado en el momento de la escritura |
| **Liberar (ceder)** | `DeleteItem` | `session = :mine` | Solo el titular actual puede liberar |

#### Adquirir (Nuevo Clúster)

```
Node A                          DynamoDB                         Node B
   |                               |                                |
   |--PutItem(condition=not_exists)-->|                             |
   |                               |<--PutItem(condition=not_exists)--|
   |                               |                                |
   |<--Success--------------------|                                |
   |                               |--ConditionalCheckFailed------->|
```

Solo un `PutItem` tiene éxito porque `attribute_not_exists` falla una vez que el elemento existe.

#### Renovar (Líder Actual)

```
Leader                          DynamoDB                         Replica
   |                               |                                |
   |--UpdateItem(session=ABC,ttl+60)->|                             |
   |<--Success--------------------|                                |
   |                               |                                |
   |                               |<--UpdateItem(session=XYZ,ttl+60)--|
   |                               |--ConditionalCheckFailed------->|
```

Solo el nodo cuya sesión coincide puede actualizar. Las réplicas que intentan renovar fallan.

#### Tomar el Control (TTL Caducado)

Esta es la ruta crítica para la conmutación por error. Cuando un líder muere, su TTL caduca y las réplicas compiten por tomar el control.

```
Time    Node A (sees expired)       DynamoDB                    Node B (sees expired)
  |            |                        |                              |
  |  Read: ttl=100, now=105            |           Read: ttl=100, now=105
  |            |                        |                              |
  |            |--PutItem(ttl<now)----->|                              |
  |            |                        |<-----PutItem(ttl<now)--------|
  |            |                        |                              |
  |            |<--Success (ttl=165)----|                              |
  |            |                        |----ConditionalCheckFailed--->|
```

**Por qué `ttl < :now` funciona:** En el momento de la escritura, DynamoDB verifica el valor *actual* de TTL. La escritura del Nodo A establece `ttl=165`. Cuando llega la escritura del Nodo B (incluso microsegundos después), la condición `ttl < now` es **falsa** porque `165 > 105`. La escritura del Nodo B falla atómicamente.

#### Liberar (Ceder)

```
Leader                          DynamoDB
   |                               |
   |--DeleteItem(session=ABC)----->|
   |<--Success--------------------|
```

Solo el titular (sesión coincidente) puede eliminar. Esto evita que un nodo obsoleto/particionado libere accidentalmente un bloqueo en poder de un nuevo líder.

### Garantías y Límites

#### Lo que Dynatroni Garantiza

1.  **Un solo líder en cualquier instante**: Las escrituras condicionales aseguran que a lo sumo un nodo posee el bloqueo.
2.  **Arrendamiento del líder limitado por TTL**: Un líder debe renovar antes de que expire el TTL o perderá el bloqueo.
3.  **Transiciones atómicas**: No hay estado intermedio donde dos nodos "mantienen" el bloqueo.
4.  **Disponibilidad sobre consistencia**: Una minoría sobreviviente puede elegir un líder (no se necesita quórum).

#### Lo que Dynatroni NO Garantiza

1.  **Tokens de cercado (fencing tokens)**: No hay un token monotónico para cercar líderes obsoletos en la capa de la aplicación. PostgreSQL maneja esto a través de IDs de línea de tiempo y posiciones de WAL.

2.  **Detección inmediata del líder**: Un líder muerto no se detecta hasta que el TTL expira. El tiempo de detección está limitado por `failover_time`.

3.  **Sincronización del reloj**: Las comparaciones de TTL asumen que los relojes están razonablemente sincronizados. Utilice NTP. Una desviación del reloj > TTL puede causar problemas.

4.  **Manejo de particiones de red**: Un líder particionado que aún puede alcanzar DynamoDB seguirá renovando. Las réplicas no tomarán el control hasta que el líder pierda la conectividad con DynamoDB.

### Análisis de Condiciones de Carrera

#### Carrera: Dos nodos arrancan simultáneamente

Ambos intentan `attribute_not_exists`. DynamoDB serializa las escrituras; exactamente una tiene éxito.

#### Carrera: El líder muere, dos réplicas compiten

Ambas leen un TTL caducado, ambas intentan `PutItem` con `ttl < :now`. La primera escritura en llegar a DynamoDB establece un TTL futuro. La condición de la segunda escritura falla porque el TTL ya no está en el pasado.

#### Carrera: Renovación lenta del líder vs. réplica ansiosa

La renovación del líder se retrasa (pausa del recolector de basura, red). La réplica ve el TTL caducado e intenta tomar el control.

-   Si `UpdateItem(session=mine)` del líder llega primero: éxito, TTL extendido
-   Si `PutItem(ttl<now)` de la réplica llega primero: éxito, nueva sesión
-   Si la actualización del líder llega después de que la réplica ganó: falla (desajuste de `session`)

En todos los casos, exactamente un nodo es líder después de que se asienta el polvo.

### Parámetros de Tiempo

Todo el tiempo se deriva de `failover_time` (60s por defecto):

| Parámetro | Valor | Propósito |
|-----------|-------|---------|
| TTL | `failover_time` | Validez del bloqueo del líder |
| loop_wait | `failover_time / 3` | Intervalo del ciclo de HA (3 renovaciones por TTL) |
| retry_timeout | `failover_time / 3` | Tiempo de espera de la operación DCS |

La relación 3:1 asegura que el líder tenga 3 oportunidades de renovar antes de que expire el TTL, tolerando fallas transitorias.

## Consejos de Entorno / Aislamiento

- Utilice una **tabla dedicada por entorno** (por ejemplo, `patroni-dynamodb-dev`).
- Si varios clústeres comparten una tabla, asegure valores de `scope` únicos para que `cluster_name` no colisione.
- La limpieza de TTL es eventualmente consistente; los elementos caducados pueden persistir brevemente.

## DynamoDB Local (Opcional)

Para pruebas locales, apunte `endpoint_url` en su configuración de Patroni a una instancia local de DynamoDB:

```yaml
dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb-local
  endpoint_url: http://localhost:8000
```

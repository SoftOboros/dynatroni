<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Configuración y Entorno

Dynatroni se configura dentro de su YAML de Patroni bajo la clave `dynamodb:`.

## Bloque Dynatroni

```yaml
dynamodb:
  region: us-east-1           # Opcional: el valor predeterminado es ca-central-1, o la resolución de región del SDK de AWS
  table_name: patroni-dynamodb # Opcional: el valor predeterminado es softoboros-patroni
  failover_time: 60           # Opcional: el valor predeterminado es 60 (dial único para costo vs. capacidad de respuesta)
  # endpoint_url: http://localhost:8000  # opcional para DynamoDB Local
```

**Valores predeterminados y resolución de región del SDK de AWS:**
- `region`: El valor predeterminado es `ca-central-1`. Si se omite, también verifica las variables de entorno `AWS_REGION` / `AWS_DEFAULT_REGION`, luego los metadatos de instancia de EC2 (IMDS).
- `table_name`: El valor predeterminado es `softoboros-patroni`.
- `failover_time`: El valor predeterminado es 60 segundos. El mínimo permitido es 15 segundos.

## Tiempo de Conmutación por Error: El Único Control

El parámetro `failover_time` controla el equilibrio entre costo y capacidad de respuesta. Todos los parámetros de tiempo se derivan de este único valor:

| failover_time | TTL | loop_wait | retry_timeout | DynamoDB ops/min | Caso de uso |
|---------------|-----|-----------|---------------|------------------|----------|
| 15s | 15s | 5s | 5s | ~24 | Conmutación rápida por error, mayor costo |
| 60s (default) | 60s | 20s | 20s | ~6 | Equilibrado |
| 180s | 180s | 60s | 60s | ~2 | Costo optimizado, conmutación por error más lenta |

**Fórmulas de tiempo derivadas:**
- `ttl` = failover_time (ventana de validez del bloqueo del líder)
- `loop_wait` = failover_time / 3 (intervalo del ciclo HA de Patroni)
- `retry_timeout` = failover_time / 3 (tiempo de espera de la operación de DCS)

El `failover_time` mínimo permitido es de 15 segundos por seguridad.

### Configuración a través de SSM Parameter Store

Para la AMI de Dumbo, `failover_time` se lee de SSM al inicio:

```bash
# Establecer failover_time para todos los nodos del clúster
aws ssm put-parameter \
  --name /softoboros/dumbo/patroni/failover_time \
  --value "60" \
  --type String \
  --overwrite
```

## Conceptos Básicos de Patroni (contexto)

```yaml
scope: my-cluster
name: node-1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

bootstrap:
  dcs:
    # Estos se derivan de failover_time por dumbo-patroni-configure.sh
    ttl: 60
    loop_wait: 20
    retry_timeout: 20
    maximum_lag_on_failover: 1048576  # 1MB lag threshold

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /data/pgdata/16/main
  bin_dir: /usr/lib/postgresql/16/bin
```

## Parámetros SSM (AMI de Dumbo)

La AMI de Dumbo lee la configuración del Almacén de Parámetros de AWS Systems Manager. Todos los parámetros usan el prefijo `/softoboros/dumbo/`.

### Parámetros Requeridos

Estos deben existir antes de iniciar la AMI:

| Parámetro | Tipo | Descripción |
|-----------|------|-------------|
| `/softoboros/dumbo/db/password` | SecureString | Contraseña del superusuario de PostgreSQL |
| `/softoboros/dumbo/db/replicator_password` | SecureString | Contraseña del usuario de replicación en streaming |

### Parámetros Opcionales

Estos tienen valores predeterminados sensatos y pueden omitirse:

| Parámetro | Tipo | Predeterminado | Descripción |
|-----------|------|---------|-------------|
| `/softoboros/dumbo/db/user` | String | `postgres` | Nombre de superusuario de PostgreSQL |
| `/softoboros/dumbo/db/db` | String | `softoboros` | Nombre de la base de datos predeterminada |
| `/softoboros/dumbo/pg/shared_buffers` | String | `256MB` | shared_buffers de PostgreSQL |
| `/softoboros/dumbo/pg/effective_cache_size` | String | `768MB` | effective_cache_size de PostgreSQL |
| `/softoboros/dumbo/pg/work_mem` | String | `8MB` | work_mem de PostgreSQL |
| `/softoboros/dumbo/pg/maintenance_work_mem` | String | `64MB` | maintenance_work_mem de PostgreSQL |
| `/softoboros/dumbo/patroni/dynamodb_table` | String | `softoboros-patroni` | Tabla de DynamoDB para la elección de líder |
| `/softoboros/dumbo/patroni/failover_time` | String | `60` | Tiempo de conmutación por error en segundos (ver abajo) |
| `/softoboros/dumbo/cloudmap_service_id` | String | (none) | ID de servicio de Cloud Map para el registro DNS |

### Creación de Parámetros Requeridos

```bash
# Crear los secretos requeridos
aws ssm put-parameter \
  --name /softoboros/dumbo/db/password \
  --type SecureString \
  --value "your-secure-password"

aws ssm put-parameter \
  --name /softoboros/dumbo/db/replicator_password \
  --type SecureString \
  --value "your-replicator-password"
```

### Ajuste de Memoria de PostgreSQL

La configuración de memoria predeterminada está dimensionada para t4g.small (2 GB de RAM). Ajústela para el tamaño de su instancia:

| Instance | shared_buffers | effective_cache_size | work_mem | maintenance_work_mem |
|----------|----------------|----------------------|----------|----------------------|
| t4g.small (2GB) | 256MB | 768MB | 8MB | 64MB |
| t4g.medium (4GB) | 512MB | 1536MB | 16MB | 128MB |
| t4g.large (8GB) | 1GB | 3GB | 32MB | 256MB |

## Variables de Entorno Comunes

Estas son típicamente usadas por scripts de arranque o plantillas:

- `AWS_REGION` – región utilizada por el SDK de AWS
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` – opcional; preferir roles de IAM en producción
- `DYNAMODB_TABLE` – utilizado por las plantillas para rellenar `dynamodb.table_name`
- `PATRONI_SCOPE` – nombre del clúster (usado como `cluster_name` en DynamoDB)
- `PATRONI_NODE_NAME` – identificador de nodo en el clúster
- `PATRONI_CONNECT_ADDRESS` – dirección anunciada para la API REST / Postgres
- `POSTGRES_PASSWORD`, `REPLICATOR_PASSWORD` – si se está creando una plantilla de autenticación en la configuración de Patroni

## Variables de Entorno de Arranque en Frío

Estas controlan el comportamiento de elección de líder en el arranque en frío. Se configuran a través de datos de usuario de EC2 o variable de entorno (la variable de entorno tiene precedencia):

| Variable | Default | Descripción |
|----------|---------|-------------|
| `DUMBO_COLD_BOOT_TIMEOUT` | 300 | Máximo de segundos a esperar por la AZ del último líder |
| `DUMBO_FORCE_LEADER_PROMOTION` | false | Omitir completamente la comprobación de arranque en frío (riesgo de pérdida de datos) |
| `DUMBO_VOLUME_ID` | (auto-detect) | ID de volumen EBS para la coincidencia de volumen en modo Docker |

**Ejemplo de datos de usuario de EC2:**
```bash
#!/bin/bash
DUMBO_COLD_BOOT_TIMEOUT=600
```

**Configuración a través de SSM:**
```bash
aws ssm put-parameter \
  --name /softoboros/dumbo/cold_boot_timeout \
  --value "600" \
  --type String \
  --overwrite
```

Consulte [Multi-AZ & Cold Start](multi-az-and-cold-start.md) para conocer el comportamiento completo del arranque en frío.

## Acceso a la Red VPC

El `pg_hba.conf` predeterminado permite conexiones desde el CIDR de la VPC `10.20.0.0/16`:

```
host    replication     replicator      10.20.0.0/16            scram-sha-256
host    all             all             10.20.0.0/16            scram-sha-256
```

Modifique `/etc/postgresql/16/main/pg_hba.conf` para diferentes CIDR de VPC.

## Consideraciones en Tiempo de Ejecución

- **Comportamiento de TTL**: Diferentes tipos de clave tienen diferentes multiplicadores de TTL:
  - `leader`: TTL = `failover_time` (ventana de validez del bloqueo)
  - `members/*`, `status`: TTL = `failover_time * 2` (sobrevivir a latidos perdidos)
  - `config`, `sync`, `failover`, `history`, `initialize`, `failsafe`: Sin TTL (persistente)

  Asegúrese de que los relojes estén sincronizados (NTP). La limpieza de TTL de DynamoDB es eventualmente consistente; los elementos caducados pueden permanecer hasta 48 horas, pero se filtran en las lecturas de la aplicación.
- **Ajuste del tiempo de conmutación por error**: use `failover_time` como el único control; los valores individuales de `ttl`, `loop_wait` y `retry_timeout` se derivan automáticamente.
- **URLs de Endpoint**: use `endpoint_url` solo para pruebas locales con DynamoDB Local.
- **Estimación de costos**: operaciones de DynamoDB ≈ 60 / failover_time por minuto por nodo.

## Ejemplo: uso de plantilla envsubst

```bash
export AWS_REGION=us-east-1
export DYNAMODB_TABLE=patroni-dynamodb
export PATRONI_SCOPE=prod-db
export PATRONI_NODE_NAME=db-1
export PATRONI_CONNECT_ADDRESS=10.0.0.10

envsubst < /etc/patroni/patroni.yml.template > /etc/patroni/patroni.yml
```

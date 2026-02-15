<p align="center">
  <img src="dynatroni.png" alt="Dynatroni" width="360">
</p>

# Dynatroni (Patroni DynamoDB DCS)

Dynatroni es un backend de Almacén de Configuración Distribuida (DCS) basado en DynamoDB para
Patroni PostgreSQL HA.

## Características

- **DynamoDB como árbitro**: elección de líder a través de operaciones atómicas de DynamoDB
- **No requiere quorum**: un solo nodo superviviente puede operar
- **Nativo de AWS**: autenticación IAM, servicio gestionado
- **Rentable**: precios por solicitud para clústeres pequeños
- **Alta disponibilidad**: replicación multi-AZ integrada de DynamoDB

## Documentación

- [Índice de la documentación](docs/README.md)
- [Instalación e inicio rápido](docs/install.md)
- [Configuración de DynamoDB](docs/dynamodb.md)
- [Configuración y entorno](docs/configuration.md)
- [Multi-AZ e inicio en frío](docs/multi-az-and-cold-start.md)
- [Promoción de emergencia](docs/break-glass.md)
- [Operaciones y resolución de problemas](docs/operations.md)

## Instalación

```bash
pip install dynatroni
```

## Configuración de la Tabla DynamoDB

Cree una tabla DynamoDB con:
- Clave de partición: `cluster_name` (String)
- Clave de ordenación: `key` (String)
- Atributo TTL: `ttl`

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

aws dynamodb update-time-to-live \
  --table-name patroni-dynamodb \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"
```

## Configuración de Patroni

En su `patroni.yml`:

```yaml
scope: my-cluster
name: node1

dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb
  # Único ajuste para el compromiso entre costo y capacidad de respuesta:
  #   15s  = conmutación rápida, ~24 operaciones DynamoDB/min
  #   60s  = equilibrado (predeterminado), ~6 operaciones/min
  #   180s = optimizado para costo, ~2 operaciones/min
  failover_time: 60
  # Opcional: para pruebas locales con DynamoDB Local
  # endpoint_url: http://localhost:8000

# Los valores de tiempo se derivan de failover_time:
#   ttl = failover_time
#   loop_wait = failover_time / 3
#   retry_timeout = failover_time / 3

# ... resto de la configuración de patroni
```

## Permisos IAM

El rol de instancia EC2 necesita:

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
...
```

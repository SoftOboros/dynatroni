```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="300">
</p>

# Compilación de Packer de Dynatroni

Esta carpeta contiene compilaciones de Packer para AMIs de Patroni + Dynatroni.

## Compilaciones Disponibles

| Plantilla | Descripción |
|----------|-------------|
| `dynatroni-debian12-arm64.pkr.hcl` | Patroni + Dynatroni mínimo (sin PostgreSQL) |
| `softoboros-dumbo-debian12-arm64.pkr.hcl` | Pila completa: PostgreSQL 16 + pgvector + pgbouncer + Patroni HA |

## Compilación Mínima de Dynatroni

### Variables de Entorno Requeridas

Configure estas antes de ejecutar `packer build`:

- `DYNATRONI_AWS_REGION`
- `DYNATRONI_SOURCE_AMI`
- `DYNATRONI_INSTANCE_TYPE`
- `DYNATRONI_SSH_USERNAME`
- `DYNATRONI_AMI_NAME`
- `DYNATRONI_AMI_DESCRIPTION`
- `DYNATRONI_SUBNET_ID`
- `DYNATRONI_SECURITY_GROUP_ID`
- `DYNATRONI_IAM_INSTANCE_PROFILE`
- `DYNATRONI_AMI_TAGS_JSON` (opcional, mapa JSON)

### Notas

- El servicio está instalado pero no habilitado por la plantilla.
- `dynatroni-configure.sh` usa variables de entorno al iniciar para renderizar `/etc/patroni/patroni.yml`.
- Esta plantilla no instala PostgreSQL; agréguelo a la compilación para un nodo completo.

## Compilación Dumbo Full Stack

La compilación Dumbo crea un nodo PostgreSQL HA listo para producción con:

- PostgreSQL 16 de PGDG
- Extensión pgvector para embeddings
- Agrupador de conexiones pgbouncer
- Patroni HA con DynamoDB DCS (Dynatroni)
- Agente AWS SSM para una gestión segura

### Salvaguardas Operativas

La AMI Dumbo incluye refuerzos para la estabilidad de producción:

**Servicios deshabilitados** (infraestructura inmutable):
- `apt-daily-upgrade.timer`, `apt-daily.timer` – sin parches en vivo
- `man-db.timer` – innecesario en servidores
- `e2scrub_all.timer` – EBS maneja la integridad

**Servicios ajustados**:
- `fstrim.timer` – 4 veces al día en lugar de semanal (distribuye la carga de IOPS)
- `postgresql @16-main` – deshabilitado; Patroni gestiona PostgreSQL
- `pgbouncer` – gestionado por `dumbo-pgbouncer.service`

**Protección de arranque en frío**:
- `dumbo-cold-boot-check.sh` evita que las réplicas obsoletas se conviertan en líderes
- Usa la elección de la marca de tiempo del punto de control cuando no existe un registro de líder anterior
- Anule con `DUMBO_FORCE_LEADER_PROMOTION=true` en user_data

### Configuración a través de SSM

La AMI Dumbo lee la configuración de Parameter Store al inicio:

| Parámetro | Descripción | Predeterminado |
|-----------|-------------|---------|
| `/softoboros/patroni/dynamodb_table` | Nombre de la tabla DynamoDB | `softoboros-patroni` |
| `/softoboros/patroni/failover_time` | Tiempo de conmutación por error (15-180s) | `60` |
| `/softoboros/postgres/replicator_password` | Contraseña de replicación | (requerida) |

### Tiempo de Conmutación por Error

El parámetro `failover_time` es el único control para el costo vs. la capacidad de respuesta:

```
15s  → Conmutación por error rápida, ~24 operaciones DynamoDB/min
60s  → Equilibrado (predeterminado), ~6 operaciones/min
180s → Costo optimizado, ~2 operaciones/min
```

Todos los valores de tiempo (ttl, loop_wait, retry_timeout) se derivan automáticamente.

### Red VPC

`pg_hba.conf` predeterminado permite conexiones desde `10.20.0.0/16`. Modifique
`/etc/postgresql/16/main/pg_hba.conf` para diferentes CIDRs de VPC.

### Opciones de Datos de Usuario

Los datos de usuario de la instancia admiten la configuración clave=valor:

```
# Emergencia: forzar la promoción del líder (riesgo de pérdida de datos)
DUMBO_FORCE_LEADER_PROMOTION=true
```
```

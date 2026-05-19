```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Operaciones y Resolución de Problemas

## Comandos de Patroni

```bash
# Show cluster members
patronictl -c /etc/patroni/patroni.yml list

# Planned switchover
patronictl -c /etc/patroni/patroni.yml switchover

# Forced failover
patronictl -c /etc/patroni/patroni.yml failover --force

# Reinitialize a replica
patronictl -c /etc/patroni/patroni.yml reinit <member-name>
```

## Systemd / Journald

```bash
systemctl status patroni
systemctl restart patroni
journalctl -u patroni -f
```

## Endpoints de Salud

```bash
curl -s http://localhost:8008/health
curl -s http://localhost:8008/primary
```

## Depuración de DynamoDB

```bash
aws dynamodb query \
  --table-name patroni-dynamodb \
  --key-condition-expression "cluster_name = :cn" \
  --expression-attribute-values '{":cn": {"S": "my-cluster"}}'
```

## Salvaguardas Operacionales de la Imagen

La AMI de Dumbo incluye varias salvaguardas para la estabilidad de la producción:

### Elección de Líder en Arranque en Frío

Cuando todo el clúster se apaga y se reinicia, se ejecuta una **verificación de arranque en frío**
antes de que Patroni inicie para evitar que una réplica obsoleta se convierta en líder:

1. Verifica DynamoDB en busca de un registro `last_leader` (escrito cada vez que un nodo se convierte en primario)
2. Si está en la misma Zona de Disponibilidad (AZ) que el último líder, procede inmediatamente como candidato a líder
3. Si está en una AZ diferente, espera a que la AZ del último líder se inicie primero
4. Recurre a la **elección por marca de tiempo de checkpoint** si no existe ningún registro `last_leader`

**Tiempo de espera**: Valor predeterminado de 5 minutos, configurable mediante la variable de entorno `DUMBO_COLD_BOOT_TIMEOUT`
o los datos de usuario de EC2 (en segundos). Debe ser menor que `TimeoutStartSec` en patroni.service.

**Elección por marca de tiempo de checkpoint**: Cada nodo registra su marca de tiempo de checkpoint de PostgreSQL;
el nodo con los datos más recientes se convierte en líder.

**Anulación de emergencia**: Establezca `DUMBO_FORCE_LEADER_PROMOTION=true` en los datos de usuario de la instancia
para omitir la verificación de arranque en frío (riesgo de pérdida de datos).

### Servicios en Segundo Plano Deshabilitados

La AMI deshabilita los servicios que interfieren con el rendimiento de la base de datos o
la infraestructura inmutable:

| Servicio | Razón |
|---------|--------|
| `apt-daily-upgrade.timer` | AMIs inmutables; sin parches en vivo |
| `apt-daily.timer` | AMIs inmutables; sin parches en vivo |
| `man-db.timer` | Innecesario en servidores |
| `e2scrub_all.timer` | EBS maneja la integridad; el escaneo de ext4 desperdicia IOPS |

### Servicios Ajustados

| Servicio | Configuración | Razón |
|---------|--------------|--------|
| `fstrim.timer` | 4 veces al día (00:00, 06:00, 12:00, 18:00) | Distribuye la carga de TRIM en lugar de un pico semanal |
| `postgresql @16-main` | Deshabilitado | Patroni gestiona el ciclo de vida de PostgreSQL |
| `pgbouncer` | Deshabilitado (predeterminado) | Gestionado por `dumbo-pgbouncer.service` |

### Agente SSM

El Agente de AWS Systems Manager está instalado y habilitado para:
- Acceso seguro a la shell sin claves SSH
- Integración con Parameter Store
- Run Command para operaciones de flota

### Reenvío de Syslog

El servicio `dumbo-syslog.service` configura rsyslog para reenviar registros a un
agregador central. Configure el destino mediante `/etc/rsyslog.d/00-softoboros-common.conf`.

## Actualizaciones Continuas de AMI (ASG)

Cuando se ejecuta Patroni en un Grupo de Autoescalado (ASG), utilice estos scripts para
actualizaciones de AMI sin tiempo de inactividad. Los scripts eliminan de forma
graciosa los nodos del clúster antes del apagado, lo que permite que el ASG inicie
instancias de reemplazo con la nueva AMI.

### Scripts de Actualización

Se proporcionan dos scripts en `/usr/local/bin/`:

| Script | Propósito |
|--------|---------|
| `patroni-upgrade-replica.sh` | Elimina la réplica de forma graciosa, luego apaga |
| `patroni-upgrade-leader.sh` | Promueve la réplica a líder, luego apaga el antiguo líder |

Ambos scripts:
- **Verifican la salud del clúster** — requieren que tanto el líder como la réplica estén en ejecución
- **Validan el rol del nodo** — salen con error si se ejecutan en el tipo de nodo incorrecto
- **Programan el apagado** — salen antes de que se complete el apagado para que SSM pueda cerrar graciosamente

### Procedimiento de Actualización

1. **Construya una nueva AMI** con código/paquetes actualizados
2. **Actualice la plantilla de lanzamiento** para hacer referencia a la nueva AMI
3. **Actualice la réplica primero**:
   - El script detiene Patroni (lo desregistra del DCS)
   - La instancia se apaga
   - El ASG lanza una nueva instancia como réplica
   - Espere a que la nueva réplica se sincronice y esté saludable
4. **Actualice el líder**:
   - El script promueve la réplica a líder (cambio de rol)
   - Espera a que se complete el cambio de rol
   - Detiene Patroni en el antiguo líder
   - La instancia se apaga
   - El ASG lanza una nueva instancia como réplica

### Ejemplos de Comandos SSM

Encuentre e identifique los nodos del clúster por rol:

```bash
# Query each instance's role via Patroni REST API
REGION="ca-central-1"
ASG_NAME="my-patroni-asg"

for INST_ID in $(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
    --output text); do

  CMD_ID=$(aws ssm send-command \
    --region "$REGION" \
    --instance-ids "$INST_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["curl -s http://127.0.0.1:8008/patroni | jq -r .role"]' \
    --query 'Command.CommandId' --output text)

  sleep 2

  ROLE=$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$CMD_ID" \
    --instance-id "$INST_ID" \
    --query 'StandardOutputContent' --output text | tr -d '[:space:]')

  echo "$INST_ID: $ROLE"
done
```

Ejecute el script de actualización en una instancia específica:

```bash
# Upgrade replica
aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$REPLICA_INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["sudo /usr/local/bin/patroni-upgrade-replica.sh"]'

# Upgrade leader (includes switchover, longer timeout)
aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$LEADER_INSTANCE" \
  --document-name AWS-RunShellScript \
  --timeout-seconds 120 \
  --parameters 'commands=["sudo /usr/local/bin/patroni-upgrade-leader.sh"]'
```

### Ejemplos de Objetivos de Makefile

```makefile
# Upgrade replica - find replica instance and run upgrade script
patroni-upgrade-replica:
	 @REGION=$${AWS_REGION:-ca-central-1}; \
	ASG_NAME=$${PATRONI_ASG:-my-patroni-asg}; \
	echo "Finding replica instance..."; \
	REPLICA_INSTANCE=""; \
	for INST_ID in $$(aws autoscaling describe-auto-scaling-groups \
		--region "$$REGION" \
		--auto-scaling-group-names "$$ASG_NAME" \
		--query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
		--output text); do \
		ROLE=$$(aws ssm send-command \
			--region "$$REGION" \
			--instance-ids "$$INST_ID" \
			--document-name AWS-RunShellScript \
			--parameters 'commands=["curl -s http://127.0.0.1:8008/patroni | jq -r .role"]' \
			--query 'Command.CommandId' --output text 2>/dev/null); \
		sleep 2; \
		ROLE_RESULT=$$(aws ssm get-command-invocation \
			--region "$$REGION" \
			--command-id "$$ROLE" \
			--instance-id "$$INST_ID" \
			--query 'StandardOutputContent' --output text 2>/dev/null | tr -d '[:space:]'); \
		if [ "$$ROLE_RESULT" = "replica" ]; then \
			REPLICA_INSTANCE="$$INST_ID"; \
			break; \
		fi; \
	done; \
	if [ -z "$$REPLICA_INSTANCE" ]; then \
		echo "ERROR: No replica found"; exit 1; \
	fi; \
	echo "Running upgrade on replica: $$REPLICA_INSTANCE"; \
	aws ssm send-command \
		--region "$$REGION" \
		--instance-ids "$$REPLICA_INSTANCE" \
		--document-name AWS-RunShellScript \
		--parameters 'commands=["sudo /usr/local/bin/patroni-upgrade-replica.sh"]'

# Upgrade leader - find leader, run switchover + upgrade script
patroni-upgrade-leader:
	 @REGION=$${AWS_REGION:-ca-central-1}; \
	ASG_NAME=$${PATRONI_ASG:-my-patroni-asg}; \
	echo "Finding leader instance..."; \
	LEADER_INSTANCE=""; \
	for INST_ID in $$(aws autoscaling describe-auto-scaling-groups \
		--region "$$REGION" \
		--auto-scaling-group-names "$$ASG_NAME" \
		--query 'AutoScalingGroups[0].Instances[?LifecycleState==`InService`].InstanceId' \
		--output text); do \
		ROLE=$$(aws ssm send-command \
			--region "$$REGION" \
			--instance-ids "$$INST_ID" \
			--document-name AWS-RunShellScript \
			--parameters 'commands=["curl -s http://127.0.0.1:8008/patroni | jq -r .role"]' \
			--query 'Command.CommandId' --output text 2>/dev/null); \
		sleep 2; \
		ROLE_RESULT=$$(aws ssm get-command-invocation \
			--region "$$REGION" \
			--command-id "$$ROLE" \
			--instance-id "$$INST_ID" \
			--query 'StandardOutputContent' --output text 2>/dev/null | tr -d '[:space:]'); \
		if [ "$$ROLE_RESULT" = "master" ] || [ "$$ROLE_RESULT" = "leader" ]; then \
			LEADER_INSTANCE="$$INST_ID"; \
			break; \
		fi; \
	done; \
	if [ -z "$$LEADER_INSTANCE" ]; then \
		echo "ERROR: No leader found"; exit 1; \
	fi; \
	echo "Running upgrade on leader: $$LEADER_INSTANCE"; \
	aws ssm send-command \
		--region "$$REGION" \
		--instance-ids "$$LEADER_INSTANCE" \
		--document-name AWS-RunShellScript \
		--timeout-seconds 120 \
		--parameters 'commands=["sudo /usr/local/bin/patroni-upgrade-leader.sh"]'
```

### Comprobaciones de Seguridad

Los scripts de actualización **se abortarán** si:

- El clúster no está saludable (falta líder o réplica)
- El script se ejecuta en el tipo de nodo incorrecto (ej. `patroni-upgrade-replica.sh` en el líder)
- El cambio de rol falla o excede el tiempo de espera (solo actualización del líder)

Esto evita interrupciones accidentales del clúster por errores del operador.

## Ajuste del Tiempo de Conmutación por Error

Ajuste el parámetro SSM `failover_time` para equilibrar el costo y la capacidad de respuesta:

```bash
# Check current setting
aws ssm get-parameter --name /softoboros/patroni/failover_time

# Update (takes effect on next Patroni restart)
aws ssm put-parameter \
  --name /softoboros/patroni/failover_time \
  --value "30" \
  --type String \
  --overwrite
```

Consulte [Configuración](configuration.md) para la tabla de derivación de failover_time.

## Problemas Comunes

- **Acceso denegado**: confirme los permisos de IAM para las acciones de DynamoDB.
- **Región incorrecta**: asegúrese de que `AWS_REGION` o `dynamodb.region` coincidan con la región de la tabla.
- **Cambio de líder**: aumente `failover_time` si el clúster es inestable (predeterminado: 60s).
- **Desincronización de reloj**: la lógica de TTL asume relojes aproximadamente sincronizados.
- **Líder atascado**: consulte [Promoción de emergencia](break-glass.md).
- **Bloqueo en arranque en frío**: verifique `/var/log/syslog` en busca de mensajes `[cold-boot-check]`;
  aumente `DUMBO_COLD_BOOT_TIMEOUT` (predeterminado 300s) en los datos de usuario si la última AZ del líder
  tarda en iniciarse; use `DUMBO_FORCE_LEADER_PROMOTION=true` solo como último recurso.
- **Desajuste de pruebas**: las pruebas locales basadas en etcd no validan Dynatroni. Use DynamoDB Local o una tabla de desarrollo cuando sea posible.
```

```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Opérations et dépannage

## Commandes Patroni

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

## Points de terminaison de santé

```bash
curl -s http://localhost:8008/health
curl -s http://localhost:8008/primary
```

## Débogage DynamoDB

```bash
aws dynamodb query \
  --table-name patroni-dynamodb \
  --key-condition-expression "cluster_name = :cn" \
  --expression-attribute-values '{":cn": {"S": "my-cluster"}}'
```

## Garanties opérationnelles de l'image

L'AMI Dumbo inclut plusieurs garanties pour la stabilité en production :

### Élection du leader au démarrage à froid

Lorsque l'ensemble du cluster est arrêté et redémarré, un **contrôle de démarrage à froid** est exécuté
avant que Patroni ne démarre pour empêcher une réplique obsolète de devenir leader :

1. Vérifie DynamoDB pour un enregistrement `last_leader` (écrit chaque fois qu'un nœud devient primaire)
2. S'il est dans la même AZ que le dernier leader, il procède immédiatement comme candidat leader
3. S'il est dans une AZ différente, il attend que l'AZ du dernier leader démarre en premier
4. Revient à l'**élection par horodatage de point de contrôle** si aucun enregistrement `last_leader` n'existe

**Délai d'attente**: Par défaut 5 minutes, configurable via la variable d'environnement `DUMBO_COLD_BOOT_TIMEOUT`
ou les données utilisateur EC2 (en secondes). Doit être inférieur à `TimeoutStartSec` dans patroni.service.

**Élection par horodatage de point de contrôle**: Chaque nœud enregistre son horodatage
de point de contrôle PostgreSQL ; le nœud avec les données les plus récentes devient leader.

**Dérogation d'urgence**: Réglez `DUMBO_FORCE_LEADER_PROMOTION=true` dans les données
utilisateur de l'instance pour contourner le contrôle de démarrage à froid (risque de perte de données).

### Services d'arrière-plan désactivés

L'AMI désactive les services qui interfèrent avec les performances de la base de données ou
l'infrastructure immuable :

| Service | Raison |
|---------|--------|
| `apt-daily-upgrade.timer` | AMIs immuables ; pas de correctifs en direct |
| `apt-daily.timer` | AMIs immuables ; pas de correctifs en direct |
| `man-db.timer` | Inutile sur les serveurs |
| `e2scrub_all.timer` | EBS gère l'intégrité ; le nettoyage ext4 gaspille les IOPS |

### Services optimisés

| Service | Configuration | Raison |
|---------|--------------|--------|
| `fstrim.timer` | 4x par jour (00:00, 06:00, 12:00, 18:00) | Répartir la charge de TRIM par rapport à un pic hebdomadaire |
| `postgresql @16-main` | Désactivé | Patroni gère le cycle de vie de PostgreSQL |
| `pgbouncer` | Désactivé (par défaut) | Géré par `dumbo-pgbouncer.service` |

### Agent SSM

L'agent AWS Systems Manager est installé et activé pour :
- Accès shell sécurisé sans clés SSH
- Intégration du Parameter Store
- Exécution de commandes pour les opérations de flotte

### Transfert Syslog

Le service `dumbo-syslog.service` configure rsyslog pour transférer les journaux
vers un agrégateur central. Configurez la destination via `/etc/rsyslog.d/00-softoboros-common.conf`.

## Mises à niveau AMI roulantes (ASG)

Lorsque vous utilisez Patroni dans un groupe Auto Scaling (ASG), utilisez ces scripts
pour des mises à niveau AMI sans interruption. Les scripts suppriment
gracieusement les nœuds du cluster avant l'arrêt, permettant à l'ASG
de lancer des instances de remplacement avec la nouvelle AMI.

### Scripts de mise à niveau

Deux scripts sont fournis dans `/usr/local/bin/` :

| Script | But |
|--------|-----|
| `patroni-upgrade-replica.sh` | Supprimer gracieusement la réplique, puis l'arrêter |
| `patroni-upgrade-leader.sh` | Promouvoir la réplique au rang de leader, puis arrêter l'ancien leader |

Les deux scripts :
- **Vérifient la santé du cluster** — exigent que le leader et la réplique soient en cours d'exécution
- **Valident le rôle du nœud** — se terminent avec une erreur s'ils sont exécutés sur le mauvais type de nœud
- **Planifient l'arrêt** — se terminent avant que l'arrêt ne soit complet afin que SSM puisse se fermer gracieusement

### Procédure de mise à niveau

1. **Construire une nouvelle AMI** avec le code/les paquets mis à jour
2. **Mettre à jour le modèle de lancement** pour référencer la nouvelle AMI
3. **Mettre à niveau la réplique en premier** :
   - Le script arrête Patroni (se désenregistre du DCS)
   - L'instance s'arrête
   - L'ASG lance une nouvelle instance en tant que réplique
   - Attendre que la nouvelle réplique se synchronise et devienne saine
4. **Mettre à niveau le leader** :
   - Le script promeut la réplique au rang de leader (basculement)
   - Attend que le basculement soit terminé
   - Arrête Patroni sur l'ancien leader
   - L'instance s'arrête
   - L'ASG lance une nouvelle instance en tant que réplique

### Exemples de commandes SSM

Trouver et identifier les nœuds du cluster par rôle :

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

Exécuter le script de mise à niveau sur une instance spécifique :

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

### Exemples de cibles Makefile

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

### Vérifications de sécurité

Les scripts de mise à niveau **avorteront** si :

- Le cluster n'est pas sain (leader ou réplique manquant)
- Le script est exécuté sur le mauvais type de nœud (par exemple, `patroni-upgrade-replica.sh` sur le leader)
- Le basculement échoue ou expire (mise à niveau du leader uniquement)

Ceci prévient les pannes accidentelles de cluster dues à une erreur de l'opérateur.

## Ajustement du temps de basculement

Ajustez le paramètre SSM `failover_time` pour équilibrer le coût et la réactivité :

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

Voir [Configuration](configuration.md) pour la table de dérivation de failover_time.

## Problèmes courants

- **Accès refusé** : confirmez les permissions IAM pour les actions DynamoDB.
- **Mauvaise région** : assurez-vous que `AWS_REGION` ou `dynamodb.region` correspond à la région de la table.
- **Rotation du leader** : augmentez `failover_time` si le cluster est instable (par défaut : 60s).
- **Décalage d'horloge** : la logique TTL suppose des horloges approximativement synchronisées.
- **Leader bloqué** : voir [Promotion d'urgence](break-glass.md).
- **Blocage au démarrage à froid** : vérifiez `/var/log/syslog` pour les messages `[cold-boot-check]` ;
  augmentez `DUMBO_COLD_BOOT_TIMEOUT` (par défaut 300s) dans les données utilisateur si l'AZ du dernier leader
  est lente à démarrer ; utilisez `DUMBO_FORCE_LEADER_PROMOTION=true` uniquement en dernier recours.
- **Inadéquation des tests** : les tests locaux basés sur etcd ne valident pas Dynatroni. Utilisez DynamoDB Local ou une table de développement lorsque possible.
```

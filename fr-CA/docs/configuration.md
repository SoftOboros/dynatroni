```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Configuration et environnement

Dynatroni est configuré dans votre fichier Patroni YAML sous la clé `dynamodb:`.

## Bloc Dynatroni

```yaml
dynamodb:
  region: us-east-1           # Optional: defaults to ca-central-1, or AWS SDK region resolution
  table_name: patroni-dynamodb # Optional: defaults to softoboros-patroni
  failover_time: 60           # Optional: defaults to 60 (single dial for cost vs responsiveness)
  # endpoint_url: http://localhost:8000  # optional for DynamoDB Local
```

**Valeurs par défaut et résolution de la région du SDK AWS :**
- `region` : Par défaut à `ca-central-1`. Si omis, vérifie également les variables d'environnement `AWS_REGION` / `AWS_DEFAULT_REGION`, puis les métadonnées de l'instance EC2 (IMDS).
- `table_name` : Par défaut à `softoboros-patroni`.
- `failover_time` : Par défaut à 60 secondes. Le minimum autorisé est de 15 secondes.

## Temps de basculement : le cadran unique

Le paramètre `failover_time` contrôle le compromis coût-réactivité. Tous
les paramètres de temporisation sont dérivés de cette valeur unique :

| failover_time | TTL | loop_wait | retry_timeout | DynamoDB ops/min | Cas d'utilisation |
|---------------|-----|-----------|---------------|------------------|----------|
| 15s | 15s | 5s | 5s | ~24 | Basculement rapide, coût plus élevé |
| 60s (default) | 60s | 20s | 20s | ~6 | Équilibré |
| 180s | 180s | 60s | 60s | ~2 | Optimisé pour le coût, basculement plus lent |

**Formules de temporisation dérivées :**
- `ttl` = failover_time (fenêtre de validité du verrou du leader)
- `loop_wait` = failover_time / 3 (intervalle du cycle HA de Patroni)
- `retry_timeout` = failover_time / 3 (délai d'expiration de l'opération DCS)

Le `failover_time` minimum autorisé est de 15 secondes pour la sécurité.

### Configuration via le magasin de paramètres SSM

Pour l'AMI Dumbo, `failover_time` est lu depuis SSM au démarrage :

```bash
# Définit le failover_time pour tous les nœuds du cluster
aws ssm put-parameter \
  --name /softoboros/dumbo/patroni/failover_time \
  --value "60" \
  --type String \
  --overwrite
```

## Principes de base de Patroni (contexte)

```yaml
scope: my-cluster
name: node-1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

bootstrap:
  dcs:
    # Ceux-ci sont dérivés de failover_time par dumbo-patroni-configure.sh
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

## Paramètres SSM (AMI Dumbo)

L'AMI Dumbo lit la configuration depuis le magasin de paramètres AWS Systems Manager.
Tous les paramètres utilisent le préfixe `/softoboros/dumbo/`.

### Paramètres requis

Ceux-ci doivent exister avant de lancer l'AMI :

| Paramètre | Type | Description |
|-----------|------|-------------|
| `/softoboros/dumbo/db/password` | SecureString | Mot de passe du superutilisateur PostgreSQL |
| `/softoboros/dumbo/db/replicator_password` | SecureString | Mot de passe de l'utilisateur de réplication en continu |

### Paramètres facultatifs

Ceux-ci ont des valeurs par défaut raisonnables et peuvent être omis :

| Paramètre | Type | Défaut | Description |
|-----------|------|---------|-------------|
| `/softoboros/dumbo/db/user` | String | `postgres` | Nom du superutilisateur PostgreSQL |
| `/softoboros/dumbo/db/db` | String | `softoboros` | Nom de la base de données par défaut |
| `/softoboros/dumbo/pg/shared_buffers` | String | `256MB` | shared_buffers de PostgreSQL |
| `/softoboros/dumbo/pg/effective_cache_size` | String | `768MB` | effective_cache_size de PostgreSQL |
| `/softoboros/dumbo/pg/work_mem` | String | `8MB` | work_mem de PostgreSQL |
| `/softoboros/dumbo/pg/maintenance_work_mem` | String | `64MB` | maintenance_work_mem de PostgreSQL |
| `/softoboros/dumbo/patroni/dynamodb_table` | String | `softoboros-patroni` | Table DynamoDB pour l'élection du leader |
| `/softoboros/dumbo/patroni/failover_time` | String | `60` | Temps de basculement en secondes (voir ci-dessous) |
| `/softoboros/dumbo/cloudmap_service_id` | String | (aucun) | ID de service Cloud Map pour l'enregistrement DNS |

### Création des paramètres requis

```bash
# Crée les secrets requis
aws ssm put-parameter \
  --name /softoboros/dumbo/db/password \
  --type SecureString \
  --value "your-secure-password"

aws ssm put-parameter \
  --name /softoboros/dumbo/db/replicator_password \
  --type SecureString \
  --value "your-replicator-password"
```

### Optimisation de la mémoire PostgreSQL

Les paramètres de mémoire par défaut sont dimensionnés pour t4g.small (2 Go de RAM). Ajustez en fonction de la taille de votre instance :

| Instance | shared_buffers | effective_cache_size | work_mem | maintenance_work_mem |
|----------|----------------|----------------------|----------|----------------------|
| t4g.small (2GB) | 256MB | 768MB | 8MB | 64MB |
| t4g.medium (4GB) | 512MB | 1536MB | 16MB | 128MB |
| t4g.large (8GB) | 1GB | 3GB | 32MB | 256MB |

## Variables d'environnement courantes

Celles-ci sont généralement utilisées par les scripts de démarrage ou les modèles :

- `AWS_REGION` – région utilisée par le SDK AWS
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` – facultatif ; préférer les rôles IAM en production
- `DYNAMODB_TABLE` – utilisé par les modèles pour remplir `dynamodb.table_name`
- `PATRONI_SCOPE` – nom du cluster (utilisé comme `cluster_name` dans DynamoDB)
- `PATRONI_NODE_NAME` – identifiant du nœud dans le cluster
- `PATRONI_CONNECT_ADDRESS` – adresse annoncée pour l'API REST / Postgres
- `POSTGRES_PASSWORD`, `REPLICATOR_PASSWORD` – si l'authentification est templatisée dans la configuration Patroni

## Variables d'environnement de démarrage à froid

Celles-ci contrôlent le comportement d'élection du leader au démarrage à froid. Définies via les données utilisateur EC2 ou une variable d'environnement (la variable d'environnement a priorité) :

| Variable | Défaut | Description |
|----------|---------|-------------|
| `DUMBO_COLD_BOOT_TIMEOUT` | 300 | Nombre maximal de secondes à attendre pour l'AZ du dernier leader |
| `DUMBO_FORCE_LEADER_PROMOTION` | false | Ignorer entièrement la vérification de démarrage à froid (risque de perte de données) |
| `DUMBO_VOLUME_ID` | (détection automatique) | ID de volume EBS pour la correspondance de volume en mode Docker |

**Exemple de données utilisateur EC2 :**
```bash
#!/bin/bash
DUMBO_COLD_BOOT_TIMEOUT=600
```

**Configuration via SSM :**
```bash
aws ssm put-parameter \
  --name /softoboros/dumbo/cold_boot_timeout \
  --value "600" \
  --type String \
  --overwrite
```

Voir [Multi-AZ & Démarrage à froid](multi-az-and-cold-start.md) pour le comportement complet du démarrage à froid.

## Accès réseau VPC

Le `pg_hba.conf` par défaut autorise les connexions depuis le CIDR VPC `10.20.0.0/16` :

```
host    replication     replicator      10.20.0.0/16            scram-sha-256
host    all             all             10.20.0.0/16            scram-sha-256
```

Modifiez `/etc/postgresql/16/main/pg_hba.conf` pour différents CIDR VPC.

## Considérations d'exécution

- **Comportement TTL** : Différents types de clés ont des multiplicateurs TTL différents :
  - `leader` : TTL = `failover_time` (fenêtre de validité du verrou)
  - `members/*`, `status` : TTL = `failover_time * 2` (survit aux battements de cœur manqués)
  - `config`, `sync`, `failover`, `history`, `initialize`, `failsafe` : Pas de TTL (persistant)

  Assurez-vous que les horloges sont synchronisées (NTP). Le nettoyage TTL de DynamoDB est finalement cohérent ; les éléments expirés peuvent persister jusqu'à 48 heures mais sont filtrés lors des lectures de l'application.
- **Réglage du temps de basculement** : utilisez `failover_time` comme cadran unique ; les valeurs individuelles `ttl`, `loop_wait` et `retry_timeout` sont dérivées automatiquement.
- **URL de point de terminaison** : utilisez `endpoint_url` uniquement pour les tests locaux avec DynamoDB Local.
- **Estimation des coûts** : Opérations DynamoDB ≈ 60 / failover_time par minute par nœud.

## Exemple : utilisation du modèle envsubst

```bash
export AWS_REGION=us-east-1
export DYNAMODB_TABLE=patroni-dynamodb
export PATRONI_SCOPE=prod-db
export PATRONI_NODE_NAME=db-1
export PATRONI_CONNECT_ADDRESS=10.0.0.10

envsubst < /etc/patroni/patroni.yml.template > /etc/patroni/patroni.yml
```
```

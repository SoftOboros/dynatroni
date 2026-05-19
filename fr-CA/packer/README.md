```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="300">
</p>

# Construction du paquet Dynatroni

Ce dossier contient les constructions Packer pour les AMI Patroni + Dynatroni.

## Constructions disponibles

| Modèle | Description |
|----------|-------------|
| `dynatroni-debian12-arm64.pkr.hcl` | Patroni + Dynatroni minimal (pas de PostgreSQL) |
| `softoboros-dumbo-debian12-arm64.pkr.hcl` | Pile complète : PostgreSQL 16 + pgvector + pgbouncer + Patroni HA |

## Construction minimale de Dynatroni

### Variables d'environnement requises

Définissez-les avant d'exécuter `packer build`:

- `DYNATRONI_AWS_REGION`
- `DYNATRONI_SOURCE_AMI`
- `DYNATRONI_INSTANCE_TYPE`
- `DYNATRONI_SSH_USERNAME`
- `DYNATRONI_AMI_NAME`
- `DYNATRONI_AMI_DESCRIPTION`
- `DYNATRONI_SUBNET_ID`
- `DYNATRONI_SECURITY_GROUP_ID`
- `DYNATRONI_IAM_INSTANCE_PROFILE`
- `DYNATRONI_AMI_TAGS_JSON` (optionnel, carte JSON)

### Remarques

- Le service est installé mais non activé par le modèle.
- `dynatroni-configure.sh` utilise les variables d'environnement au démarrage pour générer `/etc/patroni/patroni.yml`.
- Ce modèle n'installe pas PostgreSQL ; ajoutez-le à la construction pour un nœud complet.

## Construction complète de Dumbo

La construction Dumbo crée un nœud PostgreSQL HA prêt pour la production avec :

- PostgreSQL 16 de PGDG
- Extension pgvector pour les embeddings
- Pool de connexions pgbouncer
- Patroni HA avec DynamoDB DCS (Dynatroni)
- Agent AWS SSM pour une gestion sécurisée

### Mesures de sécurité opérationnelles

L'AMI Dumbo inclut un durcissement pour la stabilité de la production :

**Services désactivés** (infrastructure immuable) :
- `apt-daily-upgrade.timer`, `apt-daily.timer` – pas de correctifs en direct
- `man-db.timer` – inutile sur les serveurs
- `e2scrub_all.timer` – EBS gère l'intégrité

**Services réglés** :
- `fstrim.timer` – 4 fois par jour au lieu d'une fois par semaine (répartit la charge d'IOPS)
- `postgresql @16-main` – désactivé ; Patroni gère PostgreSQL
- `pgbouncer` – géré par `dumbo-pgbouncer.service`

**Protection au démarrage à froid** :
- `dumbo-cold-boot-check.sh` empêche les répliques obsolètes de devenir leader
- Utilise l'élection par horodatage de point de contrôle lorsqu'aucun enregistrement de leader antérieur n'existe
- Remplacez par `DUMBO_FORCE_LEADER_PROMOTION=true` dans user_data

### Configuration via SSM

L'AMI Dumbo lit la configuration depuis Parameter Store au démarrage :

| Paramètre | Description | Défaut |
|-----------|-------------|---------|
| `/softoboros/patroni/dynamodb_table` | Nom de la table DynamoDB | `softoboros-patroni` |
| `/softoboros/patroni/failover_time` | Temps de basculement (15-180s) | `60` |
| `/softoboros/postgres/replicator_password` | Mot de passe de réplication | (requis) |

### Temps de basculement

Le paramètre `failover_time` est le seul levier pour le coût par rapport à la réactivité :

```
15s → Basculement rapide, ~24 opérations DynamoDB/min
60s → Équilibré (par défaut), ~6 opérations/min
180s → Optimisé pour le coût, ~2 opérations/min
```

Toutes les valeurs de synchronisation (ttl, loop_wait, retry_timeout) sont dérivées automatiquement.

### Réseau VPC

Le `pg_hba.conf` par défaut autorise les connexions depuis `10.20.0.0/16`. Modifiez
`/etc/postgresql/16/main/pg_hba.conf` pour différents CIDR VPC.

### Options de données utilisateur

Les données utilisateur de l'instance prennent en charge la configuration clé=valeur :

```
# Urgence : forcer la promotion du leader (risque de perte de données)
DUMBO_FORCE_LEADER_PROMOTION=true
```
```

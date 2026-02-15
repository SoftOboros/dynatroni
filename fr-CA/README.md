```markdown
<p align="center">
  <img src="dynatroni.png" alt="Dynatroni" width="360">
</p>

# Dynatroni (Patroni DynamoDB DCS)

Dynatroni est un backend de magasin de configuration distribué (DCS) basé sur DynamoDB
pour Patroni PostgreSQL HA.

## Fonctionnalités

- **DynamoDB comme arbitre**: élection du leader via les opérations atomiques de DynamoDB
- **Aucune exigence de quorum**: un seul nœud survivant peut fonctionner
- **AWS-natif**: authentification IAM, service géré
- **Rentable**: tarification par requête pour les petits clusters
- **Haute disponibilité**: réplication multi-AZ intégrée de DynamoDB

## Documentation

- [Index de la documentation](docs/README.md)
- [Installation et démarrage rapide](docs/install.md)
- [Configuration de DynamoDB](docs/dynamodb.md)
- [Configuration et environnement](docs/configuration.md)
- [Multi-AZ et démarrage à froid](docs/multi-az-and-cold-start.md)
- [Promotion d'urgence](docs/break-glass.md)
- [Opérations et dépannage](docs/operations.md)

## Installation

```bash
pip install dynatroni
```

## Configuration de la table DynamoDB

Créez une table DynamoDB avec :
- Clé de partition : `cluster_name` (Chaîne)
- Clé de tri : `key` (Chaîne)
- Attribut TTL : `ttl`

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

## Configuration de Patroni

Dans votre `patroni.yml` :

```yaml
scope: my-cluster
name: node1

dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb
  # Cadran unique pour le compromis coût vs réactivité:
  #   15s  = basculement rapide, ~24 opérations DynamoDB/min
  #   60s  = équilibré (par défaut), ~6 opérations/min
  #   180s = optimisé pour les coûts, ~2 opérations/min
  failover_time: 60
  # Facultatif: pour les tests locaux avec DynamoDB Local
  # endpoint_url: http://localhost:8000

# Les valeurs de temporisation sont dérivées de failover_time:
#   ttl = failover_time
#   loop_wait = failover_time / 3
#   retry_timeout = failover_time / 3

# ... reste de la configuration patroni
```

## Permissions IAM

Le rôle d'instance EC2 nécessite :

```json
{
  "Effect": "Allow",
  "Action": [
    "dynamodb:GetItem",
    "dynamodb:PutItem",
...
```
```

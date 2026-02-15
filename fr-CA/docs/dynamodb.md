## Comportement TTL

DynamoDB TTL supprime automatiquement les éléments expirés (finalement cohérent, peut persister jusqu'à 48 heures).

| Type de clé | Valeur TTL | Notes |
|----------|-----------|-------|
| `leader` | `failover_time` | Fenêtre de validité du verrou du leader |
| `members/*` | `failover_time * 2` | Battement de cœur du membre (2x pour survivre aux battements de cœur manqués) |
| `status` | `failover_time * 2` | Statut du cluster (2x pour la cohérence avec les membres) |
| `config`, `sync`, `failover`, `history`, `initialize`, `failsafe` | Aucune | Persistant jusqu'à suppression explicite |

**Note :** Les éléments sans TTL persistent indéfiniment. Utilisez `patronictl remove` ou un nettoyage manuel pour les clusters décommissionnés.

## Créer la Table

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

Activer le TTL :

```bash
aws dynamodb update-time-to-live \
  --table-name patroni-dynamodb \
  --time-to-live-specification "Enabled=true,AttributeName=ttl"
```

## Permissions IAM

Permissions minimales pour le rôle IAM du nœud ou les informations d'identification AWS :

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

## Plongée Profonde dans l'Élection du Leader

Dynatroni implémente un verrou distribué (élection du leader) en utilisant les écritures conditionnelles de DynamoDB comme primitive atomique. Cette section détaille le mécanisme, les garanties et les limites.

### Le Mécanisme : Les Écritures Conditionnelles comme Sémaphores

Les écritures conditionnelles de DynamoDB sont **atomiques** : la vérification de la condition et l'écriture se produisent en une seule opération. Si la condition échoue, l'écriture est rejetée et l'élément reste inchangé. Cela fournit la base pour le verrouillage distribué sans nécessiter de transactions distribuées.

Chaque écriture conditionnelle agit comme une opération **comparer-et-échanger (CAS)** :
1. Lire l'état actuel (facultatif, pour la prise de décision)
2. Tenter l'écriture avec une condition qui encode l'état attendu
3. Si la condition échoue → un autre nœud a gagné ; réessayer ou reculer
4. Si la condition réussit → nous détenons le verrou

### Opérations et Leurs Conditions

| Opération | Appel DynamoDB | Condition | Pourquoi cette condition |
|-----------|---------------|-----------|-------------------|
| **Acquérir (nouveau cluster)** | `PutItem` | `attribute_not_exists(cluster_name)` | L'élément ne doit pas exister ; le premier écrivain gagne |
| **Renouveler (étendre le TTL)** | `UpdateItem` | `session = :mine` | Seul le détenteur actuel peut étendre |
| **Prendre le contrôle (TTL expiré)** | `PutItem` | `ttl < :now` | Le TTL doit toujours être expiré au moment de l'écriture |
| **Libérer (se retirer)** | `DeleteItem` | `session = :mine` | Seul le détenteur actuel peut libérer |

#### Acquérir (Nouveau Cluster)

```
Nœud A                          DynamoDB                         Nœud B
   |                               |                                |
   |--PutItem(condition=not_exists)-->|                             |
   |                               |<--PutItem(condition=not_exists)--|
   |                               |                                |
   |<--Succès--------------------|                                |
   |                               |--ConditionalCheckFailed------->|
```

Une seule `PutItem` réussit car `attribute_not_exists` échoue une fois que l'élément existe.

#### Renouveler (Leader Actuel)

```
Leader                          DynamoDB                         Réplique
   |                               |                                |
   |--UpdateItem(session=ABC,ttl+60)->|                             |
   |<--Succès--------------------|                                |
   |                               |                                |
   |                               |<--UpdateItem(session=XYZ,ttl+60)--|
   |                               |--ConditionalCheckFailed------->|
```

Seul le nœud dont la session correspond peut mettre à jour. Les répliques tentant de renouveler échouent.

#### Prendre le Contrôle (TTL Expiré)

C'est le chemin critique pour le basculement. Lorsqu'un leader tombe, son TTL expire et les répliques se précipitent pour prendre le contrôle.

```
Heure    Nœud A (voit expiré)       DynamoDB                    Nœud B (voit expiré)
  |            |                        |                              |
  |  Lecture : ttl=100, maintenant=105 |           Lecture : ttl=100, maintenant=105
  |            |                        |                              |
  |            |--PutItem(ttl<now)----->|                              |
  |            |                        |<-----PutItem(ttl<now)--------|
  |            |                        |                              |
  |            |<--Succès (ttl=165)----|                              |
  |            |                        |----ConditionalCheckFailed--->|
```

**Pourquoi `ttl < :now` fonctionne :** Au moment de l'écriture, DynamoDB vérifie la valeur TTL *actuelle*. L'écriture du nœud A définit `ttl=165`. Lorsque l'écriture du nœud B arrive (même quelques microsecondes plus tard), la condition `ttl < now` est **fausse** car `165 > 105`. L'écriture du nœud B échoue atomiquement.

#### Libérer (Se Retirer)

```
Leader                          DynamoDB
   |                               |
   |--DeleteItem(session=ABC)----->|
   |<--Succès--------------------|
```

Seul le détenteur (session correspondante) peut supprimer. Cela empêche un nœud obsolète/partitionné de libérer accidentellement un verrou détenu par un nouveau leader.

### Garanties et Limites

#### Ce que Dynatroni Garantit

1. **Leader unique à tout instant** : Les écritures conditionnelles garantissent qu'un seul nœud détient le verrou.
2. **Bail du leader limité par le TTL** : Un leader doit renouveler avant l'expiration du TTL ou perdre le verrou.
3. **Transitions atomiques** : Aucun état intermédiaire où deux nœuds "détiennent" le verrou.
4. **Disponibilité plutôt que cohérence** : Une minorité survivante peut élire un leader (pas besoin de quorum).

#### Ce que Dynatroni NE Garantit PAS

1. **Jetons d'enclave (fencing tokens)** : Il n'y a pas de jeton monotonique pour isoler les leaders obsolètes au niveau de l'application. PostgreSQL gère cela via les ID de chronologie et les positions WAL.

2. **Détection immédiate du leader** : Un leader mort n'est pas détecté avant l'expiration du TTL. Le temps de détection est limité par `failover_time`.

3. **Synchronisation d'horloge** : Les comparaisons TTL supposent que les horloges sont raisonnablement synchronisées. Utilisez NTP. Un décalage d'horloge > TTL peut causer des problèmes.

4. **Gestion des partitions réseau** : Un leader partitionné qui peut toujours atteindre DynamoDB continuera à renouveler. Les répliques ne prendront pas le contrôle tant que le leader ne perdra pas la connectivité DynamoDB.

### Analyse des Conditions de Concurrence

#### Concurrence : Deux nœuds démarrent simultanément

Les deux tentent `attribute_not_exists`. DynamoDB sérialise les écritures ; exactement une réussit.

#### Concurrence : Le leader tombe, deux répliques se précipitent

Les deux lisent un TTL expiré, les deux tentent `PutItem` avec `ttl < :now`. La première écriture à atteindre DynamoDB définit un TTL futur. La condition de la deuxième écriture échoue car le TTL n'est plus dans le passé.

#### Concurrence : Renouvellement lent du leader contre réplique impatiente

Le renouvellement du leader est retardé (pause GC, réseau). La réplique voit le TTL expiré et tente de prendre le contrôle.

- Si l'`UpdateItem(session=mine)` du leader arrive en premier : réussit, TTL étendu.
- Si le `PutItem(ttl<now)` de la réplique arrive en premier : réussit, nouvelle session.
- Si la mise à jour du leader arrive après que la réplique ait gagné : échoue (non-concordance de `session`).

Dans tous les cas, un seul nœud est leader une fois le calme revenu.

### Paramètres de Synchronisation

Toutes les synchronisations dérivent de `failover_time` (par défaut 60s) :

| Paramètre | Valeur | Objectif |
|-----------|-------|---------|
| TTL | `failover_time` | Validité du verrou du leader |
| `loop_wait` | `failover_time / 3` | Intervalle du cycle HA (3 renouvellements par TTL) |
| `retry_timeout` | `failover_time / 3` | Délai d'expiration de l'opération DCS |

Le rapport 3:1 garantit au leader 3 chances de renouveler avant l'expiration du TTL, tolérant les défaillances transitoires.

## Conseils d'Environnement / Isolation

- Utilisez une **table dédiée par environnement** (par exemple, `patroni-dynamodb-dev`).
- Si plusieurs clusters partagent une table, assurez-vous que les valeurs `scope` sont uniques afin que `cluster_name` n'entre pas en collision.
- Le nettoyage TTL est finalement cohérent ; les éléments expirés peuvent persister brièvement.

## DynamoDB Local (Facultatif)

Pour les tests locaux, pointez `endpoint_url` dans votre configuration Patroni vers une instance DynamoDB locale :

```yaml
dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb-local
  endpoint_url: http://localhost:8000
```

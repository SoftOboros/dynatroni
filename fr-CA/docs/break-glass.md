<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Promotion d'urgence (Break-Glass)

À n'utiliser que lorsque le basculement normal est bloqué et que vous acceptez le risque de perte de données ou de "split-brain" si l'opération est mal exécutée.

## Préférable : Basculement géré par Patroni

Sur un nœud sain, exécutez :

```bash
patronictl -c /etc/patroni/patroni.yml list
patronictl -c /etc/patroni/patroni.yml failover --force
```

Si le cluster est sain, utilisez plutôt un basculement contrôlé :

```bash
patronictl -c /etc/patroni/patroni.yml switchover
```

## Dernier recours : Libérer le verrou du leader

Si l'enregistrement du leader est bloqué dans DynamoDB et que l'ancien leader est confirmé comme étant hors service,
effacez la clé du leader **pour ce cluster seulement**, puis réessayez le basculement.

**Exemple (remplacer les espaces réservés) :**

```bash
aws dynamodb delete-item \
  --table-name patroni-dynamodb \
  --key '{"cluster_name": {"S": "my-cluster"}, "key": {"S": "leader"}}'
```

## Vérifications de sécurité

- Assurez-vous que l'ancien leader est **arrêté** et ne peut pas rejoindre en tant que primaire.
- Confirmez que le réplica candidat est raisonnablement à jour.
- Après la promotion, ajoutez de nouveau les anciens nœuds en tant que réplicas et validez la réplication.

## Remplacement de démarrage optionnel

Si vous implémentez un script de garde de démarrage à froid, fournissez un remplacement manuel (par exemple, une variable d'environnement `DYNATRONI_BREAK_GLASS=1`) pour contourner la garde en cas d'urgence. Documentez cela dans votre guide d'utilisation interne.

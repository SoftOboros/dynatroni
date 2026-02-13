```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Installation et démarrage rapide

## Installer le paquet Python

```bash
pip install dynatroni
```

Dynatroni est un backend Patroni DCS et est découvert via des points d'entrée. Aucune
copie manuelle de `patroni.dcs` n'est requise lors de l'installation depuis PyPI.

## Configuration Patroni minimale

```yaml
scope: my-cluster
name: node-1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 10.0.0.10:8008

dynamodb:
  region: us-east-1
  table_name: patroni-dynamodb

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 10.0.0.10:5432
  data_dir: /var/lib/postgresql/16/main
  bin_dir: /usr/lib/postgresql/16/bin
```

## Démarrer Patroni

```bash
patroni /etc/patroni/patroni.yml
```

## Suivant

- [Configuration de DynamoDB](dynamodb.md)
- [Configuration et environnement](configuration.md)
```

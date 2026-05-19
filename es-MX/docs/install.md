```markdown
<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Instalar y Inicio Rápido

## Instalar el paquete de Python

```bash
pip install dynatroni
```

Dynatroni es un backend de Patroni DCS y se descubre a través de puntos de entrada. No se
requiere copiar `patroni.dcs` manualmente al instalarlo desde PyPI.

## Configuración mínima de Patroni

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

## Iniciar Patroni

```bash
patroni /etc/patroni/patroni.yml
```

## Siguiente

- [Configuración de DynamoDB](dynamodb.md)
- [Configuración y entorno](configuration.md)
```

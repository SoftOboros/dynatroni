<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Promoción de Emergencia (Break-Glass)

Use esto solo cuando la conmutación por error normal esté bloqueada y acepte el riesgo de pérdida de datos o división de cerebros si se ejecuta incorrectamente.

## Preferido: Conmutación por Error Administrada por Patroni

En un nodo sano, ejecute:

```bash
patronictl -c /etc/patroni/patroni.yml list
patronictl -c /etc/patroni/patroni.yml failover --force
```

Si el clúster está sano, use un cambio de rol controlado en su lugar:

```bash
patronictl -c /etc/patroni/patroni.yml switchover
```

## Último Recurso: Borrar el Bloqueo del Líder

Si el registro del líder está atascado en DynamoDB y se confirma que el antiguo líder está caído,
borre la clave del líder **solo para este clúster**, luego reintente la conmutación por error.

**Ejemplo (reemplace los marcadores de posición):**

```bash
aws dynamodb delete-item \
  --table-name patroni-dynamodb \
  --key '{"cluster_name": {"S": "my-cluster"}, "key": {"S": "leader"}}'
```

## Controles de Seguridad

- Asegúrese de que el antiguo líder esté **detenido** y no pueda volver a unirse como primario.
- Confirme que la réplica candidata esté razonablemente actualizada.
- Después de la promoción, vuelva a agregar los nodos antiguos como réplicas y valide la replicación.

## Anulación de Arranque Opcional

Si implementa un script de protección de arranque en frío, proporcione una anulación manual (por
ejemplo, una variable de entorno `DYNATRONI_BREAK_GLASS=1`) para omitir la protección en
emergencias. Documente esto en su manual de procedimientos interno.

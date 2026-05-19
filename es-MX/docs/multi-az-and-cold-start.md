<p align="centre">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Multi-AZ y Arranque en Frío

## Consideraciones Multi-AZ

- **DynamoDB es regional** y de alta disponibilidad; puede ser usado como el
  árbitro del clúster a través de Zonas de Disponibilidad (AZs).
- **La latencia importa**: la latencia entre AZs influye en `loop_wait`, `ttl`, y
  `retry_timeout`. Use valores conservadores cuando las AZs estén muy separadas.
- **Dominios de falla**: ejecute al menos dos nodos en diferentes AZs para tolerar
  fallas de una sola AZ.
- **Particiones de red**: si la red es inestable, un `ttl` corto puede causar
  cambios rápidos de líder. Prefiera la estabilidad sobre la agresividad.

## Arranque en Frío (Todos los Nodos Caídos)

Cuando todo el clúster se detiene y todos los nodos se reinician simultáneamente, un
**chequeo de arranque en frío** evita que una réplica obsoleta se convierta en líder.

### Protección Automática de Arranque en Frío (AMI Dumbo)

La AMI Dumbo implementa protección automática de arranque en frío a través del
script `dumbo-cold-boot-check.sh` (se ejecuta como `ExecStartPre` antes de Patroni):

#### Seguimiento del Último Líder

Siempre que un nodo se convierte en primario (en `on_start` o `on_role_change`), Patroni
escribe un registro `last_leader` en DynamoDB que contiene:
- ID de Instancia
- Zona de Disponibilidad (con sufijo como `a`, `b`, `c`)
- ID de volumen EBS
- Marca de tiempo

Este registro persiste hasta que se elige un nuevo líder (sin TTL).

#### Lógica de Elección de Arranque en Frío

En el arranque en frío, cada nodo:

1. **Verifica en DynamoDB el registro `last_leader`**
2. **Modo AWS (IMDS disponible)**: Usa preferencia basada en AZ
   - Si está en la misma AZ que el último líder → procede inmediatamente como candidato a líder
   - Si está en una AZ diferente → espera a que la AZ del último líder se active primero
3. **Modo Docker (sin IMDS)**: Usa coincidencia de `volume_id`
   - Si es el mismo volumen que el último líder → procede inmediatamente
   - Si es un volumen diferente → espera al último líder
4. **Elección de respaldo**: Si no existe un registro `last_leader`, usa
   la marca de tiempo del checkpoint de PostgreSQL para elegir el nodo con los datos más recientes

#### Configuración

| Configuración | Fuente | Predeterminado | Descripción |
|---------|--------|---------|-------------|
| `DUMBO_COLD_BOOT_TIMEOUT` | Datos de usuario o variable de entorno | 300 (5 min) | Tiempo máximo de espera para la AZ del líder |
| `DUMBO_FORCE_LEADER_PROMOTION` | Datos de usuario o variable de entorno | false | Omite completamente el chequeo de arranque en frío |

**Ejemplo de datos de usuario:**
```bash
#!/bin/bash
DUMBO_COLD_BOOT_TIMEOUT=600    # Esperar hasta 10 minutos
```

**Anulación de emergencia:**
```bash
#!/bin/bash
DUMBO_FORCE_LEADER_PROMOTION=true  # Omite el chequeo de arranque en frío (riesgo de pérdida de datos)
```

#### Tiempo de Espera de Systemd

El chequeo de arranque en frío puede tardar hasta `DUMBO_COLD_BOOT_TIMEOUT` segundos. La
unidad `patroni.service` tiene `TimeoutStartSec=360` para acomodar esto. Ajuste
el tiempo de espera de systemd si usa un tiempo de espera de arranque en frío más largo.

### Procedimiento Manual de Arranque en Frío

Si no usa la AMI Dumbo o para recuperación ante desastres:

1. **Elija un líder de arranque** (la réplica más actualizada si es posible).
2. **Inicie el líder de arranque solo** y espere a que adquiera el liderazgo.
3. **Inicie los nodos restantes** y permítales seguirlo.

Si no puede determinar la réplica más reciente, evite forzar la promoción hasta
que confirme la seguridad de los datos.

## Cuándo Usar "Break Glass"

Consulte [Promoción de emergencia (break-glass)](break-glass.md) para opciones de promoción de emergencia.

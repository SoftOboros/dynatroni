<p align="centre">
  <img src="dynatroni.png" alt="Dynatroni" width="300">
</p>

# Registro de Cambios

## 0.1.0

### Elección de Líder en Arranque en Frío
- **Cambiado**: Se renombró `cold_boot_leader` a `last_leader` en el registro de DynamoDB
  - Ahora se escribe cada vez que un nodo se convierte en primario (en `on_start` o `on_role_change`)
  - Anteriormente, solo se escribía cuando un líder en solitario se apagaba limpiamente
- **Añadido**: Tiempo de espera configurable para el arranque en frío a través de la variable de entorno `DUMBO_COLD_BOOT_TIMEOUT` o datos de usuario de EC2 (predeterminado: 300s)
- **Añadido**: Función `load_user_data_settings()` para leer configuraciones de los datos de usuario de EC2
- **Cambiado**: `TimeoutStartSec=360` de Systemd en patroni.service para acomodar la espera del arranque en frío

### DCS de DynamoDB (dynatroni)
- **Añadido**: Limitación de tasa inteligente con modo de renovación de emergencia sensible al TTL
  - Rastrea el tiempo transcurrido real en lugar de retrasos fijos
  - Modo de emergencia al acercarse la expiración del TTL (salta el retraso)
  - Evita que los retrasos de limitación de tasa causen la expiración del TTL
- **Corregido**: `_get_item()` ahora devuelve elementos caducados por defecto (`check_ttl=False`)
  - Permite una adecuada toma de control del líder cuando el TTL ha expirado pero el elemento aún existe
  - El llamador puede optar por la verificación de TTL con `check_ttl=True`
- **Añadido**: Seguimiento del estado del líder (`_is_leader`, `_leader_lock_acquired_at`)

### Callback de Patroni
- **Añadido**: Registro de tabla del sistema para el descubrimiento de participantes de alta disponibilidad (HA)
- **Cambiado**: `record_last_leader()` se llama al convertirse en primario (tanto en `on_start` como en `on_role_change`)

### Documentación
- multi-az-and-cold-start.md actualizado con la documentación completa del comportamiento de arranque en frío
- configuration.md actualizado con las variables de entorno de arranque en frío
- operations.md actualizado con el tiempo de espera configurable y consejos para la solución de problemas

## 0.0.1
- Lanzamiento inicial extraído del monorepo de origen
```

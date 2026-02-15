<p align="center">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Documentación de Dynatroni

Bienvenido a la guía práctica de Dynatroni. Esta documentación cubre la instalación,
la configuración de DynamoDB, la configuración, las consideraciones de despliegue y los
manuales de operaciones.

## Tabla de Contenidos

- [Instalación y inicio rápido](install.md)
- [Configuración de DynamoDB](dynamodb.md)
  - [Análisis profundo de la elección del líder](dynamodb.md#leader-election-deep-dive) — cómo las operaciones atómicas aseguran un único líder
- [Configuración y entorno](configuration.md)
- [Multi-AZ e inicio en frío](multi-az-and-cold-start.md)
- [Promoción de emergencia (Break-glass promotion)](break-glass.md)
- [Operaciones y resolución de problemas](operations.md)
- [Compilación de AMI con Packer](../packer/README.md)

<p align="centre">
  <img src="../dynatroni.png" alt="Dynatroni" width="320">
</p>

# Multi-AZ et Démarrage à froid

## Considérations Multi-AZ

- **DynamoDB est régional** et hautement disponible; il peut être utilisé comme
  arbitre de cluster à travers les zones de disponibilité (AZ).
- **La latence est importante**: la latence inter-AZ influence `loop_wait`, `ttl`, et
  `retry_timeout`. Utilisez des valeurs conservatrices lorsque les AZ sont éloignées.
- **Domaines de défaillance**: exécutez au moins deux nœuds dans différentes AZ pour tolérer
  les défaillances d'une seule AZ.
- **Partitions réseau**: si le réseau est instable, un `ttl` court peut provoquer
  un roulement rapide du leader. Préférez la stabilité à l'agressivité.

## Démarrage à froid (tous les nœuds sont en panne)

Lorsque l'ensemble du cluster est arrêté et que tous les nœuds redémarrent simultanément, une
**vérification de démarrage à froid** empêche un réplica périmé de devenir leader.

### Protection automatique contre le démarrage à froid (AMI Dumbo)

L'AMI Dumbo implémente une protection automatique contre le démarrage à froid via le
script `dumbo-cold-boot-check.sh` (s'exécute en tant que `ExecStartPre` avant Patroni) :

#### Suivi du dernier leader

Chaque fois qu'un nœud devient primaire (sur `on_start` ou `on_role_change`), Patroni
écrit un enregistrement `last_leader` dans DynamoDB contenant :
- ID de l'instance
- Zone de disponibilité (avec suffixe comme `a`, `b`, `c`)
- ID du volume EBS
- Horodatage

Cet enregistrement persiste jusqu'à ce qu'un nouveau leader soit élu (pas de TTL).

#### Logique d'élection au démarrage à froid

Au démarrage à froid, chaque nœud :

1. **Vérifie l'enregistrement `last_leader` dans DynamoDB**
2. **Mode AWS (IMDS disponible)**: Utilise la préférence basée sur l'AZ
   - Si dans la même AZ que le dernier leader → procède immédiatement en tant que candidat leader
   - Si dans une AZ différente → attend que l'AZ du dernier leader soit opérationnelle en premier
3. **Mode Docker (pas d'IMDS)**: Utilise la correspondance `volume_id`
   - Si le même volume que le dernier leader → procède immédiatement
   - Si un volume différent → attend le dernier leader
4. **Élection de secours**: Si aucun enregistrement `last_leader` n'existe, utilise
   l'horodatage du checkpoint PostgreSQL pour élire le nœud avec les données les plus récentes

#### Configuration

| Setting | Source | Default | Description |
|---------|--------|---------|-------------|
| `DUMBO_COLD_BOOT_TIMEOUT` | User data ou variable d'environnement | 300 (5 min) | Temps d'attente maximum pour l'AZ du leader |
| `DUMBO_FORCE_LEADER_PROMOTION` | User data ou variable d'environnement | false | Ignore complètement la vérification de démarrage à froid |

**Exemple de données utilisateur :**
```bash
#!/bin/bash
DUMBO_COLD_BOOT_TIMEOUT=600    # Attendre jusqu'à 10 minutes
```

**Dérogation d'urgence :**
```bash
#!/bin/bash
DUMBO_FORCE_LEADER_PROMOTION=true  # Ignorer la vérification de démarrage à froid (risque de perte de données)
```

#### Délai d'attente Systemd

La vérification de démarrage à froid peut prendre jusqu'à `DUMBO_COLD_BOOT_TIMEOUT` secondes. L'unité
`patroni.service` a `TimeoutStartSec=360` pour s'adapter à cela. Ajustez
le délai d'attente systemd si vous utilisez un délai d'attente de démarrage à froid plus long.

### Procédure de démarrage à froid manuel

Si vous n'utilisez pas l'AMI Dumbo ou pour la reprise après sinistre :

1. **Choisissez un leader de démarrage** (le réplica le plus à jour si possible).
2. **Démarrez le leader de démarrage seul** et attendez qu'il acquière le leadership.
3. **Démarrez les nœuds restants** et laissez-les suivre.

Si vous ne pouvez pas déterminer le réplica le plus récent, évitez de forcer la promotion tant que vous
n'avez pas confirmé la sécurité des données.

## Quand utiliser "Break Glass"

Voir [Promotion d'urgence](break-glass.md) pour les options de promotion d'urgence.

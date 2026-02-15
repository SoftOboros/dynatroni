```markdown
<p align="centre">
  <img src="dynatroni.png" alt="Dynatroni" width="300">
</p>

# Journal des modifications

## 0.1.0

### Élection du leader au démarrage à froid
- **Modifié**: Renommé `cold_boot_leader` en `last_leader` dans l'enregistrement DynamoDB
  - Maintenant écrit chaque fois qu'un nœud devient primaire (sur `on_start` ou `on_role_change`)
  - Auparavant, écrit uniquement lorsqu'un leader solo s'arrêtait proprement
- **Ajouté**: Délai de démarrage à froid configurable via la variable d'environnement `DUMBO_COLD_BOOT_TIMEOUT` ou les données utilisateur EC2 (par défaut: 300s)
- **Ajouté**: Fonction `load_user_data_settings()` pour lire les paramètres des données utilisateur EC2
- **Modifié**: `TimeoutStartSec=360` de Systemd dans patroni.service pour accommoder l'attente du démarrage à froid

### DynamoDB DCS (dynatroni)
- **Ajouté**: Limitation de débit intelligente avec mode de renouvellement d'urgence tenant compte du TTL
  - Suit le temps réel écoulé au lieu de délais fixes
  - Mode d'urgence à l'approche de l'expiration du TTL (ignore le délai)
  - Empêche les retards de limitation de débit de causer l'expiration du TTL
- **Corrigé**: `_get_item()` retourne maintenant les éléments expirés par défaut (`check_ttl=False`)
  - Permet une prise de contrôle appropriée du leader lorsque le TTL est expiré mais que l'élément existe toujours
  - L'appelant peut activer la vérification du TTL avec `check_ttl=True`
- **Ajouté**: Suivi de l'état du leader (`_is_leader`, `_leader_lock_acquired_at`)

### Rappel Patroni
- **Ajouté**: Enregistrement de la table système pour la découverte des participants HA
- **Modifié**: `record_last_leader()` appelé lors de la transition vers le rôle primaire (à la fois `on_start` et `on_role_change`)

### Documentation
- Mise à jour de multi-az-and-cold-start.md avec la documentation complète du comportement de démarrage à froid
- Mise à jour de configuration.md avec les variables d'environnement de démarrage à froid
- Mise à jour de operations.md avec le délai configurable et des conseils de dépannage

## 0.0.1
- Première version extraite du monorepo source
```
```

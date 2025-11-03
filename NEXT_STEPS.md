Next Steps
==========

### Statut actuel
- ✅ SwiftPM structure en place (`Package.swift`, modules BoxCommandParser/BoxServer/BoxClient/BoxCore).
- ✅ CLI/admin intégrés (`status`, `ping`, `log-target`, `reload-config`, `stats`, `nat-probe`, `locate`).
- ✅ Stockage persistant (`~/.box/queues/` + `INBOX` obligatoire, queues permanentes).
- ✅ Location Service prototype (publication directe dans `whoswho/`, réponses CLI et UDP synchronisées, résumé `locationService` exposé via `box admin status|stats`).
- ✅ Port mapping optionnel (UPnP → PCP MAP/PEER → NAT-PMP) + reachability probe.
- ✅ Tests Swift (`swift test --parallel`) couvrant CLI et flux UDP (timeouts 30 s).
- ✅ Commande `box init-config` pour créer/réparer `Box.plist` et préparer `~/.box/{queues,logs,run}`.
- ✅ CLI `box put`/`box get` (queues éphémères & permanentes) couvert par `BoxCLIIntegrationTests`.
- 🚧 Noise/libsodium non activé (transport clair uniquement).

### Priorités courtes (S3+)
1. **Supervision racines (alerting)**
   - Exploiter les métriques `locationService` pour déclencher des alertes (`staleNodes`, `staleUsers`) et fournir un exemple d’intégration (Prometheus, script CLI).
2. **Préparation Noise (S4)**
   - Définir la structure de stockage des clés (identité nœud, utilisateur).
   - Ajouter des tests d’encapsulation libsodium (unitaires) en clair pour préparer l’intégration.

### Moyenne échéance
3. **CLI intégration E2E supplémentaire**
   - ✅ Cycle PUT/GET (queues permanentes et éphémères) validé via `BoxCLIIntegrationTests`.
   - Préparer une commande d’export `whoswho` (`box admin export-presence`) pour les clients mobiles.
4. **Admission control**
   - Implémenter la vérification que (user_uuid, node_uuid) est connu avant de répondre aux requêtes non-admin.
   - Ajouter des tests négatifs (`unauthorized`).
5. **Mobile / clients légers**
   - Définir un format exportable du `whoswho` pour consommation Android/iOS.
   - Produire une CLI `box admin export-presence` pour préparer cette consommation.

### Long terme
6. **Validation nat-probe matérielle**
   - Capturer un scénario « succès » (UPnP/PCP) dès que du matériel compatible est disponible, puis ajouter le test CLI correspondant.
7. **Noise/libsodium**
   - Implémenter NK/IK `HELLO` + handshake complet, tests de relecture.
   - Synchroniser SPECS.md avec le framing chiffré.
8. **/location queue**
   - Publier les informations géographiques (`latitude`, `longitude`, etc.).
   - Tests de cohérence et documentation pour les clients mobiles.
9. **Windows support**
    - Implémenter le transport admin `\\.\pipe\boxd-admin`.
    - Adapter `BoxPaths` et tests pour Windows (file locking, permissions).

### Modalités
- Chaque tâche doit inclure : code + tests + doc.
- Respecter les conventions Swift (`CODE_CONVENTIONS.md`) et les dépendances notées dans `DEPENDENCIES.md`.
- Éviter tout retour aux artefacts supprimés (C, CMake, scripts bash historiques).

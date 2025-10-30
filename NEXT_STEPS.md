Next Steps
==========

### Statut actuel
- ✅ SwiftPM structure en place (`Package.swift`, modules BoxCommandParser/BoxServer/BoxClient/BoxCore).
- ✅ CLI/admin intégrés (`status`, `ping`, `log-target`, `reload-config`, `stats`, `nat-probe`, `locate`).
- ✅ Stockage persistant (`~/.box/queues/` + `INBOX` obligatoire, queues permanentes).
- ✅ Location Service prototype (publication dans `whoswho/`, réponses CLI et UDP synchronisées).
- ✅ Port mapping optionnel (UPnP → PCP MAP/PEER → NAT-PMP) + reachability probe.
- ✅ Tests Swift (`swift test --parallel`) couvrant CLI et flux UDP (timeouts 30 s).
- 🚧 Noise/libsodium non activé (transport clair uniquement).

### Priorités courtes (S3+)
1. **Unifier la persistance `whoswho`**
   - Écrire directement depuis `BoxServer` sans passerelle `/uuid` intermédiaire.
   - Tester la rotation de fichiers `<uuid>.json` (mise à jour en place) et la suppression des doublons.
2. **Supervision racines**
   - Ajouter des métriques/test d’intégration vérifiant qu’un nœud racine perçoit `last_seen <= 120 s`.
   - Fournir un script ou une commande `box admin status --root-summary`.
3. **Génération PLIST automatisée**
   - Fournir `swift run box admin init-config` (ou équivalent) qui crée `~/.box/Box.plist` si absent et vérifie la présence des UUID.
4. **Préparation Noise (S4)**
   - Définir la structure de stockage des clés (identité nœud, utilisateur).
   - Ajouter des tests d’encapsulation libsodium (unitaires) en clair pour préparer l’intégration.

### Moyenne échéance
5. **CLI intégration E2E supplémentaire**
   - Étendre `BoxCLIIntegrationTests` pour couvrir un cycle PUT/GET complet en mode permanent vs éphémère.
   - Ajouter un test `nat-probe` « succès » dès qu’un routeur compatible UPnP/PCP est disponible.
6. **Admission control**
   - Implémenter la vérification que (user_uuid, node_uuid) est connu avant de répondre aux requêtes non-admin.
   - Ajouter des tests négatifs (`unauthorized`).
7. **Mobile / clients légers**
   - Définir un format exportable du `whoswho` pour consommation Android/iOS.
   - Produire une CLI `box admin export-presence` pour préparer cette consommation.

### Long terme
8. **Noise/libsodium**
   - Implémenter NK/IK `HELLO` + handshake complet, tests de relecture.
   - Synchroniser SPECS.md avec le framing chiffré.
9. **/location queue**
   - Publier les informations géographiques (`latitude`, `longitude`, etc.).
   - Tests de cohérence et documentation pour les clients mobiles.
10. **Windows support**
    - Implémenter le transport admin `\\.\pipe\boxd-admin`.
    - Adapter `BoxPaths` et tests pour Windows (file locking, permissions).

### Modalités
- Chaque tâche doit inclure : code + tests + doc.
- Respecter les conventions Swift (`CODE_CONVENTIONS.md`) et les dépendances notées dans `DEPENDENCIES.md`.
- Éviter tout retour aux artefacts supprimés (C, CMake, scripts bash historiques).

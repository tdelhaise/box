Development Strategy
====================

### Assumptions
- Codebase : Swift 6.2 (async/await) avec SwiftNIO, swift-argument-parser, swift-log. Plus aucune dépendance directe à l’ancienne base C.
- Binaire unique `box` (client par défaut, serveur via `--server/-s`) géré par SwiftPM.
- Plateformes cibles : Linux/macOS en priorité, Windows en préparation. Préférence IPv6 natif.
- Référence de protocole : `SPECS.md` (framing v1, queues permanentes, Location Service, NAT, future Noise).

### Principes directeurs
- Former des incréments livrables et entièrement testés (unitaires + intégrations CLI ≤ 30 s).
- Tenir la documentation à jour à chaque itération (README, SPECS, NEXT_STEPS, DEPENDENCIES).
- Préparer l’intégration Noise/libsodium sans bloquer les livraisons courantes.
- Toujours préserver l’exécutable unique (client+serveur).

### Jalons Swift

**S0 — Bootstrap toolchain**
- `Package.swift`, structure `swift/Sources` & `swift/Tests`.
- CI GitHub Actions: installation Swift 6.2 via Swiftly, exécution `swift build` + `swift test --parallel`.
- Sortie : binaire `box` fonctionnel (+ tests unitaires vides).

**S1 — CLI & Journalisation**
- `BoxCommandParser` (swift-argument-parser) gère le mode serveur (`--server/-s`) et les options partagées.
- Initialiser swift-log (backend Puppy) avec cibles fichier par défaut (`~/.box/logs/box(.d).log`).
- Validations : `swift run box --help`, tests CLI de base.

**S2 — Réseau clair**
- Portage SwiftNIO du flux UDP HELLO → STATUS → PUT → GET.
- `BoxCodec` commun client/serveur, `BoxServerStore` persistant sur disque (`~/.box/queues`).
- Tests d’intégration UDP (`BoxClientServerIntegrationTests`) couvrant PUT/GET et autorisation.

**S3 — Configuration & Administration**
- Fichier unique `~/.box/Box.plist` (sections `common`, `server`, `client`) + génération automatique des UUID.
- Canal admin unifié (`box admin status|ping|log-target|reload-config|stats|nat-probe|locate`), abstraction Unix socket / future named pipe Windows.
- NAT tooling : IPv6 probe, UPnP → PCP (MAP/PEER) → NAT-PMP, reachability HELLO, télémétrie partagée (admin + Location Service).
- Publication Location Service via `LocationServiceCoordinator`, enregistrement `whoswho/<uuid>.json`, queue `INBOX`, support des queues permanentes.
- Tests CLI intégrés (`BoxCLIIntegrationTests`) exécutés en CI.

**S4 — Crypto (à venir)**
- Ajouter bindings libsodium, implémenter Noise NK/IK, XChaCha20-Poly1305.
- Rejouer les suites de tests en mode chiffré (HELLO/STATUS/PUT/GET).
- Ajouter vérification signature pour les échanges racines et la publication LS.

### Travaux opérationnels
- **Racines** : déployer 3 serveurs IPv6 statiques (OVHcloud Advance‑2, Hetzner AX52, Scaleway/Exoscale). Chaque nœud Box rafraîchit `whoswho` toutes les 60 s. Alerting si `last_seen > 120 s`.
- **Surveillance** : exporter journaux enrichis (ISO 8601 + métadonnées). Mettre en place Prometheus/Grafana (ou équivalent léger) hors cluster racine.
- **Sécurité** : authentification mutuelle Noise prévue pour chaque échange racine⇔nœud. Distribution des clés publiques via canal hors bande. Politique non-root stricte.

### Backlog court terme (extraits)
Voir `NEXT_STEPS.md` pour la liste détaillée. Priorités actuelles :
1. Exploiter les métriques `locationService` (alerting, supervision racines, intégration observabilité).
2. Préparer le passage Noise/libsodium (structures de clés, tests unitaires).
3. Approfondir la couverture CLI/integration (export LS à court terme; scénario nat-probe « succès » sera traité après la 0.4.0, une fois le matériel compatible disponible).
4. Préparer les SDK mobiles :
   - iOS : module SwiftPM `BoxMobileClient` (wrap `BoxClient`, API PUT/GET/LOCATE, documentation d’intégration).
   - Android : réimplémentation native Kotlin (pas de bridging Swift/Kotlin), planifiée pour un jalon post‑0.4.0.

### Structure de documentation
- `README.md` — aperçu, build, topologie racines, commandes essentielles.
- `SPECS.md` — protocole (frames, queues, Location Service, NAT).
- `NEXT_STEPS.md` — roadmap courte (S3+ features, crypto, mobile).
- `CODE_CONVENTIONS.md` — style et architecture Swift.
- `DEPENDENCIES.md` — prérequis (Swift, libsodium, tooling).

### Rappels
- Ne pas réintroduire de modules C ou CMake.
- Toute nouvelle fonctionnalité doit être couverte par des tests et documentée.
- Les tests CI restent le garde-fou (échec `swift test` = PR bloquée).

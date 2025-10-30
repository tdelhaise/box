## Box — Réécriture Swift

Box est une messagerie orientée files d’attente (« queues ») pensée pour fonctionner en environnement hostile : dépendance minimale vis‑à‑vis du DNS, priorité à l’IPv6 natif et contrôle strict des identités (UUID utilisateur + UUID nœud). Le dépôt est désormais 100 % Swift 6.2 / SwiftPM ; l’ancienne implémentation C (sources, CMake, scripts) a été retirée.

### Prérequis
- Toolchain Swift 6.2 (recommandé : [Swiftly](https://www.swift.org/install/linux/#swiftly), `swiftly install 6.2.0` puis `swiftly use 6.2.0`).
- macOS 14+ ou Linux (amd64/arm64) avec IPv6 global si possible.
- `libsodium` reste requis à terme pour Noise/XChaCha, mais la phase courante fonctionne en clair.
- Pour l’administration distante : accès SSH non-root et UFW/nftables configuré en `default deny`.

### Construction et tests
```bash
# Construire le binaire SwiftPM (client + serveur dans le même exécutable)
swift build --product box

# Lancer la batterie de tests (unitaires + intégrations CLI, timeout 30 s par scénario)
swift test --parallel
```

### Démarrage rapide
- Serveur : `swift run box --server [--port 12567] [--address ::]`
- Client : `swift run box [--address <ip|[ipv6]>] [--port <udp>]`
- Canal admin (même exécutable) : `swift run box admin status` ou `swift run box admin locate <uuid>`

L’admin s’appuie sur `~/.box/run/boxd.socket` (Unix) ou `\\.\pipe\boxd-admin` (Windows, à venir). L’exécutable refuse de tourner en root/admin et crée automatiquement `~/.box/{logs,queues,run}` avec permissions restreintes.

### Configuration (`~/.box/Box.plist`)
- Section `common` : `node_uuid`, `user_uuid` (générés au premier lancement et persistés).
- Section `server` : `port`, `address`, `log_level`, `log_target` (par défaut `file:~/.box/logs/boxd.log`), `port_mapping`, `external_address`, `external_port`, `permanent_queues`.
- Section `client` : `address`, `port`, `log_target`, préférences d’auto‑locate.
- Les paramètres CLI prennent le pas, puis les variables d’environnement, puis le fichier PLIST.
- Lors de la première exécution, une queue `INBOX` et la file permanente `whoswho/` sont créées sous `~/.box/queues/`.
- `swift run box init-config [--rotate-identities] [--json]` crée ou répare `Box.plist` (UUID garantis, sections par défaut) et prépare `~/.box/{queues,logs,run}`.
- Les identités Noise sont gérées par `BoxNoiseKeyStore` (`~/.box/keys/node.identity.json` et `client.identity.json` en hex JSON, prêtes pour l’intégration libsodium).

### Topologie « root resolvers »
- Une installation de développement peut se contenter d’un VPS OVH VPS‑2/3 (Ubuntu 24.04/25.04) avec IPv6 statique : cloner le dépôt, installer Swift 6.2, lancer `swift run box --server`.
- En production : au moins **trois** serveurs racines géographiquement distincts et fournis aux clients sous forme d’adresses IPv6 statiques. Recommandation actuelle (~265 €/mois HT) :
  - OVHcloud Advance‑2 (Roubaix) — ≈ 120 €.
  - Hetzner AX52 (Falkenstein) — ≈ 65 €.
  - Scaleway EM-A5800 (Paris) ou Exoscale équivalent — ≈ 80 €.
- Aucun load balancer ni DNS dynamique : chaque client conserve une liste triée de racines (`Box.plist` → `common.root_servers`). À chaque minute, tout serveur Box publie sa présence vers chaque racine (`whoswho/<node_uuid>.json` et `whoswho/<user_uuid>.json`). Deux rafraîchissements manqués (> 120 s) marquent l’entrée comme expirée.
- Les échanges racine⇔nœud seront signés via Noise/libsodium (en cours) afin d’éviter les faux relais.

### Localisation & queues permanentes
- `LocationServiceCoordinator` publie un `LocationServiceNodeRecord` commun aux réponses admin et aux fichiers `whoswho/`. Chaque enregistrement contient : adresses IPv6/IPv4 (origine `probe|config|manual`), état NAT/port mapping (`portMapping*`), métadonnées de reachability, timestamp `lastPresenceUpdate`.
- `box admin locate <uuid>` résout aussi bien un User UUID qu’un Node UUID : en mode utilisateur, la réponse agrège tous les nœuds encore « actifs » (`last_seen <= 120 s`).
- Les queues déclarées dans `server.permanent_queues` ne consomment pas leurs messages lors des `GET`; `BoxServerStore` expose désormais `peek` pour les restituer plusieurs fois.

### NAT et connectivité
- Sonde IPv6 automatique au démarrage (`hasGlobalIPv6`, `globalIPv6Addresses`, `ipv6ProbeError`).
- Option `--enable-port-mapping` / `port_mapping = true` : séquence UPnP → PCP (`MAP` + `PEER`) → NAT‑PMP, puis sonde `HELLO` sur l’endpoint externe. Télemetrie renvoyée via admin : `portMappingStatus`, `portMappingBackend`, `portMappingPeer*`, `portMappingReachability*`, etc.
- `swift run box admin nat-probe [--gateway <ip>]` exécute la séquence côté CLI (tests en CI attendent `disabled|skipped` lorsque le mapping est désactivé).
- `swift run box admin location-summary [--json] [--fail-on-stale] [--fail-if-empty]` inspecte `whoswho/` (affiche les nœuds actifs/stale et retourne un code ≠ 0 selon les options, utile pour la supervision des racines).
- Pas de dépendance STUN/ICE ; si la passerelle ne supporte pas ces protocoles, configurer un forwarding manuel et renseigner `external_address/external_port`.

### Tests end-to-end
- `BoxCLIIntegrationTests` couvre `box admin status|ping|locate|nat-probe|location-summary` et `box --locate`. Chaque test se termine en < 30 s par design (`XCTExpectFailure` si timeout).
- `BoxClientServerIntegrationTests` vérifie PUT/GET/LOCATE via UDP, y compris le comportement « permanent queue ».
- Pour lancer manuellement une session de test : `swift test --filter BoxCLIIntegrationTests.testNatProbeDisabled`.

### Structure du dépôt
- `Package.swift`, `Package.resolved`
- `swift/Sources/` — `BoxCommandParser`, `BoxCore`, `BoxServer`, `BoxClient`, `BoxAdmin`
- `swift/Tests/` — suites unitaires et intégration Swift (`BoxAppTests`, `BoxCLIIntegrationTests`, etc.)
- `systemd/boxd.service` — exemple à adapter (`ExecStart=/usr/local/bin/box --server`)
- `pki/` — autorités de test utilisées par les suites crypto (préparation Noise)
- `NEXT_STEPS.md`, `DEVELOPMENT_STRATEGY.md`, `SPECS.md` — feuille de route et spécification de protocole

### Documentation complémentaire
- **SPECS.md** — protocole, format des queues, enregistrements Location Service (`whoswho`).
- **DEVELOPMENT_STRATEGY.md** — jalons Swift (S0–S4), opérations/hosting, intégration libsodium à venir.
- **NEXT_STEPS.md** — backlog court terme (alerting racines, init-config, préparation Noise/libsodium).
- **AGENTS.md** — aide-mémoire pour les contributeurs.

### Contribution
Le dépôt suit les conventions Swift décrites dans `CODE_CONVENTIONS.md`. Avant toute contribution :
1. formater via `swift format` (ou `swift-format` si disponible),
2. exécuter `swift test --parallel`,
3. mettre à jour la documentation lorsque le comportement change.

Les contributions portant sur l’ancienne base C ne sont plus acceptées.

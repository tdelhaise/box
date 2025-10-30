Agents Guide
============

### Docs à lire en priorité
- **SPECS.md** — protocole (framing, queues, Location Service, NAT).
- **DEVELOPMENT_STRATEGY.md** — roadmap Swift (S0–S4), hébergement racines.
- **CODE_CONVENTIONS.md** — style Swift, restrictions sur les identifiants.
- **DEPENDENCIES.md** — toolchain Swift, libsodium (optionnel), commandes utiles.
- **NEXT_STEPS.md** — tâches courtes à traiter en priorité.

### Build & tests
- `swift build --product box`
- `swift test --parallel`
- CLI durant le dev : `swift run box …`
- Les tests d’intégration disposent tous d’un timeout ≤ 30 s. Ne pas modifier ces garde-fous.

### Points d’attention
- **Swift only** : aucun retour de C, CMake ou scripts bash historiques.
- **Binaire unique** : `box` fait office de client et serveur (`--server`).
- **Admin channel** : `swift run box admin <cmd>` via socket Unix `~/.box/run/boxd.socket` (commandes `status|ping|log-target|reload-config|stats|nat-probe|locate|location-summary`).
- **Configuration** : fichier unique `~/.box/Box.plist` (sections `common`, `server`, `client`). Génération auto des UUID si absent.
- **Init config** : `swift run box init-config [--rotate-identities] [--json]` crée/répare le PLIST et prépare `~/.box/{queues,logs,run}`.
- **Identités Noise** : `BoxNoiseKeyStore` écrit les clefs placeholder dans `~/.box/keys/node.identity.json` et `client.identity.json` (hex JSON en attendant libsodium).
- **Location Service** : enregistrements JSON (`whoswho/<node_uuid>.json`, `whoswho/<user_uuid>.json`), rafraîchissement toutes les 60 s, même builder que les réponses admin.
- **Réseau** : privilégier IPv6 global; `--enable-port-mapping` déclenche UPnP → PCP (MAP+PEER) → NAT-PMP + reachability HELLO. Les champs `portMapping*`, `manualExternal*`, `hasGlobalIPv6`, etc., doivent rester cohérents entre runtime, admin et LS.
- **Stockage** : `~/.box/queues/<queue>/`. `INBOX` est obligatoire. Les queues listées dans `server.permanent_queues` ne détruisent pas les messages lors d’un `GET`.
- **Journalisation** : swift-log (via Puppy). Par défaut logs en `~/.box/logs/box(.d).log`, format ISO 8601 + niveau + composant + métadonnées (fichier, fonction, thread).
- **Non-root** : le binaire refuse de démarrer avec des privilèges élevés.

### Où coder ?
- `swift/Sources/BoxCommandParser` — parsing CLI + injection runtime.
- `swift/Sources/BoxServer` — runtime serveur, admin handlers, NAT/LS.
- `swift/Sources/BoxClient` — logique client (PUT/GET/LOCATE).
- `swift/Sources/BoxCore` — types partagés (config, codecs, helpers).
- `swift/Tests/…` — tests unitaires (BoxAppTests) & intégrations (BoxCLIIntegrationTests, BoxClientServerIntegrationTests).

### Do / Don’t
- ✅ Petits patchs, tests + docs à chaque changement.
- ✅ Conserver la cohérence admin ↔ Location Service ↔ documentation.
- ✅ Vérifier `swift test --parallel` avant de pousser.
- ❌ Réintroduire des traces de l’implémentation C (sources, scripts, doc).
- ❌ Modifier les timeouts d’intégration (30 s max).
- ❌ Laisser des `print` en production (utiliser `Logger`).

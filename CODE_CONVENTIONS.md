Code Conventions
================

This document captures the shared style and architectural guidelines for the Swift implementation of Box.

## Architecture
- Single executable `box` controlled by `BoxCommandParser`; client mode par défaut, serveur via `--server`/`-s`.
- Transport: UDP sur IPv6 prioritaire, IPv4 en repli. Un seul port UDP configurable par nœud.
- Protocole: encodage binaire v1 avec en-tête (`magic`, `version`, `length`, `command`, `request_id`, `node_id`, `user_id`). Commandes implémentées : HELLO, STATUS, PUT, GET, LOCATE, ADMIN (`status|ping|log-target|reload-config|stats|nat-probe`).
- Location Service: persistance des présences dans les queues `whoswho/<node_uuid>.json` et `whoswho/<user_uuid>.json`; même builder que les réponses admin.
- Sécurité: non-root obligatoire, ACL par défaut « deny », préparation Noise/libsodium (S4). Les échanges racine⇔nœud devront être signés.

## Swift Style
- Modules : `BoxCore`, `BoxServer`, `BoxClient`, `BoxCommandParser`, `BoxAdmin`.
- Types en `PascalCase`, fonctions/méthodes en `camelCase`, constantes en `lowerCamelCase`.
- Pas de préfixe `BF`. Privilégier des noms précis (`BoxRuntimeOptions`, `LocationServiceCoordinator`).
- Documenter les types/méthodes/propriétés publics avec `///`.
- Logging via `swift-log` (`Logger`). Aucune utilisation de `print` pour la journalisation structurée ; utiliser `logger.<level>` avec métadonnées.
- Asynchronisme: privilégier `async/await`, `Task`, `Actor` et les primitives SwiftNIO (`EventLoopGroup`, `ChannelPipeline`). Éviter la création manuelle de threads.
- Identifiants interdits (liste indicative) : `addr`, `buf`, `cfg`, `cnt`, `ctx`, `dst`, `env`, `idx`, `len`, `ptr`, `src`. Remplacer par des formes explicites (`address`, `buffer`, `configuration`, etc.).

## Répertoires
- `swift/Sources/BoxCommandParser` : parsing CLI, injection `BoxRuntimeOptions`.
- `swift/Sources/BoxServer` : logique serveur, stockage, Location Service, NAT/port mapping.
- `swift/Sources/BoxClient` : actions client (PUT/GET/LOCATE) et transport UDP.
- `swift/Sources/BoxCore` : types partagés (configuration, codecs, utilitaires).
- `swift/Tests` : tests unitaires (`BoxAppTests`) et intégration (`BoxCLIIntegrationTests`, `BoxClientServerIntegrationTests`).

## Tests
- Utiliser `XCTest`. Chaque test d’intégration doit disposer d’un timeout ≤ 30 s.
- Couvrir les nouveaux chemins via tests unitaires ciblés. Pour les scénarios CLI/admin, ajouter des cas dans `BoxCLIIntegrationTests`.
- Lancer `swift test --parallel` avant tout commit.

## Configuration & chemins
- Fichier unique `~/.box/Box.plist` (sections `common`, `server`, `client`).
- Dossiers créés avec permissions strictes (`0700`) : `~/.box`, `~/.box/logs`, `~/.box/run`, `~/.box/queues`.
- Admin socket : `~/.box/run/boxd.socket` (Unix). Windows utilisera `\\.\pipe\boxd-admin` (à venir).
- Journaux : `~/.box/logs/box.log` (client) et `~/.box/logs/boxd.log` (serveur) par défaut.

## Dépendances
- Swift 6.2 (minimum).
- Swift packages : `swift-argument-parser`, `swift-log`, `swift-nio`.
- `libsodium` sera requis lors de la réintégration Noise (S4). Devs peuvent installer `pkg-config libsodium` pour préparer la transition.

## Bonnes pratiques
- Patches atomiques et autoportants, documentés.
- Toutes modifications comportementales doivent être accompagnées d’une mise à jour de la documentation (`README`, `SPECS`, etc.).
- Ne jamais réintroduire de fichiers C, Makefile ou CMakeLists supprimés.

Pour toute divergence avec ce guide, aligner la documentation et mentionner l’écart dans la revue.

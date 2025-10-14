## Réécriture Swift (en cours)

- Objectif : migrer `box` vers Swift 6.2 (async/await) avec SwiftNIO, swift-argument-parser et swift-log, tout en conservant un binaire unique capable de jouer le rôle client ou serveur.
- Structure SwiftPM : `Package.swift` à la racine, sources dans `swift/Sources/…`, tests dans `swift/Tests/…`. Le projet Xcode historique a été retiré; utilisez Xcode via SwiftPM (`xed .` ou `open Package.swift`).
- Compilation rapide :
  ```bash
  swift build --product box
  swift run box --help
  swift run box --server        # équivalent à --server/-s
  swift run box                 # mode client par défaut
  ```
- `BoxCommandParser` résout la ligne de commande et délègue à `BoxServer` ou `BoxClient`. Les options actuelles couvrent `--server/-s`, `--port`, `--address`, `--config` (PLIST), `--log-level`, `--put /queue[:type] --data "..."` et `--get /queue`.
- `box admin status` interroge le socket Unix local (`~/.box/run/boxd.socket`) et renvoie un JSON de statut.
- `BoxCodec` encapsule le framing v1 (HELLO/STATUS/PUT/GET) et peut être réutilisé dans n’importe quel handler SwiftNIO basé sur `ByteBuffer`.
- Le protocole est pour l’instant implémenté en clair le temps de porter l’ensemble des fonctionnalités. La réintégration Noise/libsodium arrivera une fois le socle Swift stabilisé.
- Les fichiers de configuration basculent vers le format Property List (PLIST). La lecture TOML existante est gelée et sera réintroduite ultérieurement si nécessaire.

### Exemples (Swift cleartext)

Terminal 1 — serveur:
```bash
swift run box --server --port 12567
```

Terminal 2 — client (handshake uniquement):
```bash
swift run box --address 127.0.0.1 --port 12567
```

Terminal 2 — client PUT:
```bash
swift run box --address 127.0.0.1 --port 12567 --put /demo:text/plain --data "Hello SwiftNIO"
```

Terminal 2 — client GET:
```bash
swift run box --address 127.0.0.1 --port 12567 --get /demo
```

Les logs indiquent la progression HELLO → STATUS → action. Les réponses GET affichent la taille et le type du contenu stocké en mémoire.

### Configuration (PLIST)

- Serveur: `~/.box/boxd.plist` (CLI `--config` pour personnaliser le chemin). Exemples de clés : `port` (UInt16), `log_level` (`trace|debug|info|warn|error|critical`), `transport`, `pre_share_key`, `noise_pattern`, `admin_channel` (booléen).
- Client: `~/.box/box.plist` (réservation pour les prochaines étapes).
- Priorité des sources (serveur): CLI `--port` > variable d’environnement `BOXD_PORT` > PLIST > valeur par défaut `12567`.
- Un répertoire `~/.box` est créé au démarrage avec permissions strictes (`0700`) ainsi que `~/.box/run` (`0700`) pour héberger le socket admin (`0600`).

> Les sections suivantes décrivent l'implémentation C historique, conservée comme référence pendant la migration.

## Notes / Status (chemin C historique – gelé)

- Chiffrement (implémentation C) : en cours d’intégration — transport basé sur libsodium (Noise + XChaCha20‑Poly1305).
  - AEAD (XChaCha20‑Poly1305) présent et testé; le transport Noise encapsule les messages (`NZ v1` + nonce + ciphertext) avec protection de rejeu côté réception.
  - Chemin de démonstration: `--transport noise` sur box/boxd avec `--pre-share-key` (temporaire en attendant NK/IK).
- DTLS/OpenSSL: supprimés.
- Les échanges UDP clairs sont utilisés pour le prototypage du protocole (HELLO/STATUS, PUT/GET) et coexistent avec le chemin Noise de démonstration.

Après Intall

```bash
sudo systemd-tmpfiles --create /usr/share/tmpfiles.d/boxd.conf
# ou
# sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/boxd.conf
```

Remarque: LTO peut nécessiter l'outil "ar" compatible (par ex. llvm-ar avec Clang). Si le compilateur Clang est utilisé sur Linux, on peut exporter :
```bash
export CC=clang CXX=clang++
export AR=llvm-ar RANLIB=llvm-ranlib
```

## Utilisation (box / boxd)

Les binaires `box` (client) et `boxd` (serveur) permettent des échanges de démonstration UDP (HELLO/STATUS, PUT/GET) en local. Un canal d’administration local est disponible sur Unix (socket Unix).

### Journalisation

- Cible par défaut selon la plateforme (modifiable via `--log-target`):
  - Windows: `eventlog`
  - macOS: `oslog` (bascule sur `syslog` si `os/log.h` indisponible)
  - Unix: `syslog`
  - Autres: `stderr`
- Exemple de redirection vers stderr (pratique pour tests locaux): `./boxd --log-target stderr`
- Au démarrage, `box` et `boxd` journalisent leurs paramètres résolus, notamment: `port`, `portOrigin`, `logLevel`, `logTarget` et, côté serveur, `cert`, `key`, `pskId`, `psk` (indiqué `[set]`/`(unset)`), `transport`.

### Ports et origine

- `boxd` (serveur): la valeur finale du port suit l’ordre de priorité suivant et la source est indiquée dans `portOrigin`:
  1) `--port <udp>` (portOrigin=`cli-flag`)
  2) variable d’environnement `BOXD_PORT` (portOrigin=`env`)
  3) valeur par défaut (portOrigin=`default`) — actuellement `12567`
- `box` (client): le port peut être fourni en positionnel (`[port]`, portOrigin=`positional`) ou via `--port <udp>` (portOrigin=`cli-flag`). À défaut, la valeur par défaut est utilisée (portOrigin=`default`).

### Client `box`

Afficher l’aide:
```bash
./build/box --help

# Interroger le canal d’admin local (Unix):
./build/box admin status
```

### Serveur `boxd`

Remarques:
- L’option `--log-target` permet de diriger la journalisation vers `stderr|syslog|oslog|eventlog|file:<path>`.
- Le binaire refuse de démarrer en tant que root (Unix/macOS).
- Canal d’administration (Unix): socket `~/.box/run/boxd.socket` (droits 0600). Commande supportée: `status` (retour JSON).

### Aide (`--help`)

Sortie simplifiée des aides intégrées:

Client `box`:
```
Usage: box [address] [port] [--port <udp>] [--put <queue>[:type] <data>] [--get <queue>]
          [--transport <clear|noise>] [--protocol <simple|v1>] [--pre-share-key <ascii>]
          [--version] [--help]
```

Serveur `boxd`:
```
Usage: boxd [--port <udp>] [--log-level <lvl>] [--log-target <tgt>]
          [--protocol <simple|v1>] [--cert <pem>] [--key <pem>]
          [--pre-share-key-identity <id>] [--pre-share-key <ascii>]
          [--version] [--help]
```

### Exemple de bout-en-bout (PreShareKey)

Terminal 1 — serveur:
```bash
./build/boxd \
  --pre-share-key-identity box-client \
  --pre-share-key secretpsk \
  --transport noise
```

Terminal 2 — client:
```bash
./build/box \
  --pre-share-key-identity box-client \
  --pre-share-key secretpsk \
  --transport noise \
  127.0.0.1 12567
```

Observation attendue (logs):
- le serveur reçoit un datagramme initial, mélange les paramètres Noise (PSK + identités facultatives), envoie un HELLO applicatif, puis répond PONG aux PINGs.
- le client réalise la même dérivation Noise, affiche le HELLO du serveur, envoie un PING et affiche le PONG.

Remarques:
- Le chiffrement (Noise + XChaCha) repose aujourd’hui sur un pré-partage simple (`--pre-share-key`). La dérivation NK/IK est en cours d’industrialisation. Voir DEVELOPMENT_STRATEGY.md.

### Configuration

Fichier optionnel: `~/.box/boxd.toml` (Unix/macOS). Clés reconnues:

```
port = 12567
log_level = "info"    # trace|debug|info|warn|error
log_target = "syslog"  # stderr|syslog|oslog|eventlog|file:/path
protocol = "simple"    # simple|v1
transport = "clear"    # clear|noise (général)
transport_status = "clear"
transport_put = "clear"
transport_get = "clear"
```

Priorité des sources (port, niveau et cible de log):

- CLI (`--port`, `--log-level`, `--log-target`)
- Variables d’environnement (ex: `BOXD_PORT` pour le port)
- Fichier `~/.box/boxd.toml`
- Valeurs par défaut

## Conventions

Ce dépôt suit une convention de nommage pour la bibliothèque "BoxFoundation" afin de garder une correspondance claire entre composants, fichiers et en-têtes publics.

- Fichiers et en-têtes: préfixe `BF` pour les composants BoxFoundation.
  - Exemples: `BFCommon`, `BFSocket`, `BFUdp`, `BFUdpClient`, `BFUdpServer`, `BFBoxProtocol`.
  - Mapping fichiers:
    - `include/box/BFCommon.h` ↔ `src/lib/BFCommon.c`
    - `include/box/BFSocket.h` ↔ `src/lib/BFSocket.c`
    - `include/box/BFUdp.h` ↔ `src/lib/BFUdp.c`
    - `include/box/BFUdpClient.h` ↔ `src/lib/BFUdpClient.c`
    - `include/box/BFUdpServer.h` ↔ `src/lib/BFUdpServer.c`
    - `include/box/BFBoxProtocol.h` ↔ `src/lib/BFBoxProtocol.c`

- Tests: utiliser le préfixe `test_` suivi du nom du composant.
  - Exemple: `test/test_BFBoxProtocol.c` avec la cible CMake `test_BFBoxProtocol`.

## Conteneurs partagés (BoxFoundation)

Deux conteneurs thread-safe simples sont fournis:

- `BFSharedArray`: Tableau pseudo-indexé basé sur une liste doublement chaînée.
  - Opérations: Push (fin), Unshift (début), Insert (à l'index), Get, Set, RemoveAt, Clear.
  - Sécurité: Accès protégé par mutex; allocations via `BFMemory`.
- `BFSharedDictionary`: Dictionnaire à clés chaîne de caractères.
  - Implémentation: table de hachage avec chaînage séparé; clés dupliquées en interne.
  - API: Create/Free/Count, Set/Get/Remove, Clear; callback optionnel pour détruire les valeurs restantes.

Exemple rapide (BFSharedDictionary):

```
#include "box/BFSharedDictionary.h"
#include "box/BFMemory.h"

static void destroy_value(void *p) { BFMemoryRelease(p); }

BFSharedDictionary *d = BFSharedDictionaryCreate(destroy_value);
char *val = (char*)BFMemoryAllocate(6); // "hello\0"
memcpy(val, "hello", 6);
(void)BFSharedDictionarySet(d, "key", val);
char *got = (char*)BFSharedDictionaryGet(d, "key");
// ... utiliser got ...
BFSharedDictionaryFree(d);
```
### Tests de charge et benchmarks

- Tests de charge (concurrents):
  - Cibles: `test_BFSharedArrayStress`, `test_BFSharedDictionaryStress`
  - Par défaut, la charge est réduite pour des exécutions rapides CI/locales.
  - Pour augmenter la charge: `BOX_STRESS_ENABLE=1 ctest -R Stress --output-on-failure`

- Benchmarks (micro):
  - Construire et exécuter: `make bench`
  - Binaries: `bench_BFSharedArray`, `bench_BFSharedDictionary` (dans `build/`)

- Macros d’options CMake: préfixe `BOX_`.
  - Exemple: `BOX_USE_PRESHAREKEY` (alias rétrocompatible `BOX_USE_PSK`).

- En-têtes publics installés sous `include/box/` et accessibles via `#include "box/<Header>.h"`.

## Mémoire (BFMemory)

Le module `BFMemory` fournit une abstraction thread-safe pour l'allocation/libération afin de faciliter le débogage et la traçabilité mémoire.

- API:
  - `void *BFMemoryAllocate(size_t size)` — alloue de la mémoire (zéro-initialisée), thread-safe.
  - `void BFMemoryRelease(void *ptr)` — libère la mémoire, thread-safe (ignore `NULL`).
  - `void BFMemoryGetStats(BFMemoryStats *out)` — récupère les compteurs courant/pic (octets, blocs).
  - `void BFMemoryDumpStats(void)` — affiche les compteurs via le logger (`BFLog`).

- Traçage optionnel:
  - Définir `BF_MEMORY_TRACE=1` dans l'environnement active un dump automatique des stats à la sortie du processus.
  - Sur plateformes POSIX, l'envoi d'un signal `SIGUSR1` au processus provoque un dump immédiat:
    - `kill -USR1 <pid>`
  - Remarque: le handler `SIGUSR1` est destiné au débogage (I/O non async-signal-safe).
  - Le handler peut être désactivé à la compilation via CMake: `-DBOX_MEMORY_SIGNAL_TRACE=OFF`.

## Build Debug & Traçage Mémoire

Pour faciliter le débogage, vous pouvez compiler en mode Debug et activer le traçage mémoire de `BFMemory`.

1) Construire en Debug

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build -j
```

2) Activer le traçage à l'exécution et lancer le binaire

```bash
export BF_MEMORY_TRACE=1            # active le dump auto à la sortie
./build/boxd &                      # ou ./build/box
PID=$!
```

3) Déclencher un dump des stats à la demande (POSIX)

```bash
kill -USR1 "$PID"                  # imprime les compteurs via BFLog
```

4) Arrêter et observer le dump final (atexit)

```bash
kill "$PID"
```

## Réécriture Swift (en cours)

- Objectif : migrer `box` vers Swift 6.2 (async/await) avec SwiftNIO, swift-argument-parser et swift-log, tout en conservant un binaire unique capable de jouer le rôle client ou serveur. La CI installe manuellement la toolchain Swift 6.2 (Ubuntu 22.04) en attendant un support natif des runners.
- Structure SwiftPM : `Package.swift` à la racine, sources dans `swift/Sources/…`, tests dans `swift/Tests/…`. Le projet Xcode historique a été retiré; utilisez Xcode via SwiftPM (`xed .` ou `open Package.swift`).
- Toolchain recommandée : installez Swift 6.2 via [Swiftly](https://www.swift.org/install/linux/#swiftly) (`swiftly install 6.2.0` puis `swiftly use 6.2.0`) ou récupérez l’archive officielle `swift-6.2-RELEASE` si vous préférez l’installation manuelle.
- Compilation rapide :
  ```bash
  swift build --product box
  swift run box --help
swift run box --server        # équivalent à --server/-s
swift run box                 # mode client par défaut
```
- Par défaut, le serveur se lie à toutes les interfaces (`0.0.0.0`). Utilisez `--address <ip>` pour restreindre l'écoute.
- `BoxCommandParser` résout la ligne de commande et délègue à `BoxServer` ou `BoxClient`. Les options actuelles couvrent `--server/-s`, `--port`, `--address`, `--config` (PLIST), `--log-level`, `--log-target (stderr|stdout|file:<path>)`, `--enable-port-mapping`/`--no-enable-port-mapping`, `--put /queue[:type] --data "..."`, `--get /queue` et `--locate <uuid>` (requête Location Service via UDP – résout aujourd’hui un nœud unique comme auparavant).
- `box admin status` interroge le socket Unix local (`~/.box/run/boxd.socket`) et renvoie un JSON de statut.
- `BoxCodec` encapsule le framing v1 (HELLO/STATUS/PUT/GET) avec en-tête enrichi (`request_id` UUID, `node_id`, `user_id`) et peut être réutilisé dans n’importe quel handler SwiftNIO fondé sur `ByteBuffer`.
- Les journaux vont par défaut dans `~/.box/logs/` (`box.log` pour le client, `boxd.log` pour le serveur). Les cibles `stderr`/`stdout` restent disponibles via `--log-target` ou `Box.plist` et chaque entrée est horodatée (ISO 8601 + millisecondes) tout en exposant niveau, composant et contexte (`fichier:ligne`, fonction, thread, métadonnées).
- Le protocole est pour l’instant implémenté en clair le temps de porter l’ensemble des fonctionnalités. La réintégration Noise/libsodium arrivera une fois le socle Swift stabilisé.
- Les fichiers de configuration basculent vers le format Property List (PLIST). La lecture TOML existante est gelée et sera réintroduite ultérieurement si nécessaire.

### Connectivité & IPv6

- IPv6 reste la voie privilégiée. Par défaut, `box --server` se lie à `0.0.0.0`; définissez `--address ::` ou configurez `server.address` dans `Box.plist` pour exposer explicitement une interface IPv6. Sur un Raspberry Pi ou une machine domestique recevant un préfixe IPv6 global, cela permet une exposition directe sans redirection NAT.
- Le serveur sonde l’hôte au démarrage et lors des rechargements pour détecter la présence d’adresses IPv6 globales. Les champs `hasGlobalIPv6`, `globalIPv6Addresses` et `ipv6ProbeError` sont exposés via `box admin status|stats` et publiés dans l’enregistrement Location Service afin que les clients mobiles puissent tester les routes disponibles.
- IPv4 reste le repli obligatoire. Si aucune adresse IPv6 globale n’est détectée, les journaux et le canal d’administration avertissent qu’une redirection NAT devra être configurée. L’option `--enable-port-mapping` (ou `port_mapping = true` dans `Box.plist`) déclenche désormais une tentative automatique : UPnP (`M-SEARCH` → `AddPortMapping`) puis, en repli, NAT-PMP (`MAP`/`UNMAP` sur le gateway détecté). Chaque étape est journalisée et l’état (`portMappingEnabled`, `portMappingOrigin`) reste reflété côté admin/Location Service pour la télémétrie.
- La Location Service diffuse désormais pour chaque nœud un tableau `addresses[]` (port + IP + portée + source) et un bloc `connectivity` reprenant l’instantané ci-dessus. Les clients iOS/Android interrogent ces champs et tentent d’abord les adresses IPv6 globales (source `probe`), puis les éventuelles adresses configurées ou IPv4 de secours.
- `boxd` publie automatiquement cet enregistrement dans la file `/uuid` via le coordonnateur Location Service (acteur Swift) afin que la résolution s’appuie sur les mêmes données que l’admin channel. La file `/uuid` contient systématiquement deux entrées par serveur actif : `<node_uuid>.json` pour la présence du nœud et `<user_uuid>.json` pour l’index utilisateur (liste de nœuds). Les helpers de résolution (par utilisateur ou nœud) sont prêts pour l’intégration CLI/handshake ; la file `/location` sera branchée dans une itération ultérieure.
- Documentez ou forcez l’adresse publique (via `common.public_addresses` à venir ou `server.address`) si la machine est multi-homée ou derrière un relais, afin que la Location Service reflète correctement les routes accessibles depuis l’extérieur.

### Avancement 2025-10-14

- Transport d’administration unifié: `box admin` s’appuie désormais sur une abstraction commune (socket Unix `~/.box/run/boxd.socket` ou named pipe Windows `\\.\pipe\boxd-admin`) et prend en charge `status`, `ping`, `log-target`, `reload-config`, `stats` **et `locate <uuid>`** (résolution Location Service côté serveur, qu’il s’agisse d’un nœud ou d’un utilisateur).
- Rechargement dynamique des configurations PLIST serveur/client avec priorité CLI > env > fichier, mise à jour des cibles Puppy (`stderr|stdout|file:`) et journalisation centralisée via `BoxLogging`.
- Un fichier de configuration unique `~/.box/Box.plist` est généré au premier lancement. Il contient trois sections : `common` (UUID de nœud `node_uuid` et UUID d’utilisateur `user_uuid` partagés entre client et serveur), `server` (port, `log_level`, `log_target`, options de transport, `admin_channel`) et `client` (adresse/port par défaut, niveau et cible de log). Client et serveur se synchronisent sur ces identités persistantes et `box admin status` expose le `node_uuid` actif.
- Stockage persistant: le serveur initialise une hiérarchie `~/.box/queues/` dès le premier démarrage, garantit la présence d’une file `INBOX` et persiste chaque message sous forme de fichier JSON (`timestamp-<uuid>.json`, sauf pour `/uuid` qui écrit directement `<uuid>.json` afin d’écraser proprement les entrées de présence). Le queue `/uuid` regroupe à la fois les enregistrements de nœud et l’index utilisateur. `box admin status` et `box admin stats` exposent le chemin racine, le nombre de files (minimum 1 grâce à `INBOX`), le nombre d’objets et l’espace disque libre disponible.
- Tests Swift couvrant les commandes d’administration côté répartiteur (`BoxAdminDispatcherTests`), les parcours ping/log-target/reload-config via socket Unix (`BoxAdminIntegrationTests`), les échanges client↔️serveur HELLO/PUT/GET sur UDP (`BoxClientServerIntegrationTests`) **et** la commande `locate` côté admin/UDP (autorisation par nœud/utilisateur). Les prochains jalons porteront sur l’orchestration complète via la CLI (`swift run box …`) et la réintégration Noise/libsodium.

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

Terminal 2 — client LOCATE (résolution Location Service):
```bash
swift run box --address 127.0.0.1 --port 12567 --locate CA62C378-4525-4B40-8656-D10B555704BE
```

Les logs indiquent la progression HELLO → STATUS → action. Les réponses GET affichent la taille et le type du contenu stocké en mémoire.
La commande `--locate` côté client (UDP) ne renvoie des informations que si le serveur connaît l’identité (couple `node_id`/`user_id`) du client ; dans le cas contraire la réponse est `unauthorized` côté UDP et aucun détail n’est divulgué. `box admin locate` applique la même politique d’autorisation mais accepte désormais indifféremment un UUID de nœud ou d’utilisateur (dans ce dernier cas, la réponse liste tous les nœuds actifs appartenant à l’utilisateur).

### Configuration (PLIST)

- Fichier unique: `~/.box/Box.plist` (surcharge via `--config`). Structure :
  - `common`: `node_uuid` et `user_uuid` (UUID générés au premier lancement et réutilisés par le client comme par le serveur).
  - `server`: `port`, `log_level`, `log_target`, paramètres de transport (`transport`, `transport_status`, `transport_put`, `transport_get`), `admin_channel`, `port_mapping` (booléen), options Noise futures. La valeur par défaut `log_target` pointe vers `file:~/.box/logs/boxd.log` et `port_mapping` vaut `false` (activable via CLI ou PLIST).
  - `client`: `address`, `port`, `log_level`, `log_target` par défaut pour le mode client (par défaut `file:~/.box/logs/box.log`).
- Priorité des sources: CLI > variables d’environnement (`BOXD_PORT` pour le port serveur) > PLIST > valeurs par défaut (adresse `0.0.0.0` côté serveur, `127.0.0.1` côté client, port `12567`).
- Les identifiants `node_uuid`/`user_uuid` sont consumés pour signer chaque trame réseau (via `BoxCodec`).
- Un répertoire `~/.box` est créé au démarrage avec permissions strictes (`0700`) ainsi que `~/.box/run` (`0700`) et `~/.box/logs/` (stockage des fichiers `box.log`/`boxd.log`). La journalisation repose sur Puppy via swift-log.

### Commandes d’administration

- `swift run box admin status` : renvoie un JSON avec les métadonnées runtime.
- `swift run box admin ping` : vérifie la disponibilité du canal d’administration (`{"status":"ok","message":"pong"}`).
- `swift run box admin log-target <stderr|stdout|file:/chemin>` : met à jour dynamiquement la cible de journalisation Puppy.
- `swift run box admin reload-config [--configuration <plist>]` : recharge le PLIST serveur, met à jour le niveau/cible de log et rafraîchit les drapeaux d’exécution (CLI > config > valeur par défaut).
- `swift run box admin stats` : renvoie un instantané JSON (port, transport, cible de log, compte d’objets, compteur de reload et dernier statut).
- `swift run box admin locate <uuid>` : renvoie le dernier enregistrement Location Service connu pour le nœud ciblé, ou, si un UUID utilisateur est fourni, l’index des nœuds actifs de cet utilisateur (dans le cas contraire une erreur `node-not-found` est renvoyée).

> Remarque : la communication admin repose sur un socket Unix (`~/.box/run/boxd.socket`) sur Linux/macOS et sur un named pipe Windows (`\\.\pipe\boxd-admin`).

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

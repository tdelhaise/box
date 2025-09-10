## Some usefull comments


## Certificats de test

Générer un certificat autosigné pour DTLS :
```bash
openssl req -x509 -newkey rsa:2048 -keyout server.key \
-out server.pem -days 365 -nodes -subj "/CN=boxd"
```

Générer un certificat client autosigné (facultatif, pour démos avec certificats côté client) :
```bash
openssl req -x509 -newkey rsa:2048 -keyout client.key \
-out client.pem -days 365 -nodes -subj "/CN=box"
```

Utilisation du secret cookie en prod :

Définir une variable d’environnement BOX_COOKIE_SECRET (32+ chars aléatoires) pour des cookies stables (sinon un secret aléatoire sera généré à chaque lancement).
```bash
export BOX_COOKIE_SECRET="$(openssl rand -hex 32)"
./boxd
```

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

## Modes DTLS: Certificats ou PreShareKey

Ce projet supporte deux modes d'authentification DTLS:

- Certificats: charge `server.pem` et `server.key` (par défaut si présents).
- PreShareKey: identifiant + clé pré-partagée.

Contrôle à la configuration (CMake):

```bash
cmake -S . -B build -DBOX_USE_PRESHAREKEY=ON  # active le mode PreShareKey
cmake --build build -j
```

Dans le code, utilisez `BFDtlsConfig` pour fournir l'identité et la clé si vous ne souhaitez pas utiliser les valeurs par défaut:

```c
BFDtlsConfig cfg = {
  .certificateFile = NULL,
  .keyFile = NULL,
  .preShareKeyIdentity = "box-client",
  .preShareKey = (const unsigned char*)"secretpsk",
  .preShareKeyLength = 9,
  .cipherList = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:PSK-AES128-GCM-SHA256"
};

BFDtls *d_server = BFDtlsServerNewEx(udp_fd, &cfg);
BFDtls *d_client = BFDtlsClientNewEx(udp_fd, &cfg);
```

Note: les API/ciphers OpenSSL conservent l’acronyme historique "PSK" (ex. `SSL_CTX_set_psk_*`, `PSK-AES128-GCM-SHA256`).

## Utilisation (box / boxd)

Les binaires `box` (client) et `boxd` (serveur) acceptent des options pour configurer DTLS à l’exécution. Si aucune option n’est fournie, les valeurs par défaut sont utilisées (certificats `server.pem`/`server.key` si présents, sinon PreShareKey si activé à la compilation).

### Client `box`

Certificats (DTLS avec certificats X.509):
```bash
./build/box --cert client.pem --key client.key 127.0.0.1 12567
```

PreShareKey (DTLS avec clé pré-partagée):
```bash
./build/box \
  --pre-share-key-identity box-client \
  --pre-share-key secretpsk \
  127.0.0.1 12567
```

Afficher l’aide:
```bash
./build/box --help
```

### Serveur `boxd`

Certificats:
```bash
./build/boxd --cert server.pem --key server.key
```

PreShareKey:
```bash
./build/boxd \
  --pre-share-key-identity box-client \
  --pre-share-key secretpsk
```

Remarques:
- L’option `--pre-share-key` attend une chaîne ASCII, utilisée telle quelle comme octets PSK (exemples/démo). Pour la production, prévoir un mécanisme de fourniture/chargement sécurisé (env, fichier, KMS).
- Si au moins une option DTLS (`--cert`, `--key`, `--pre-share-key-identity`, `--pre-share-key`) est fournie, la configuration explicite est utilisée; sinon la configuration implicite (par défaut) est appliquée.

### Aide (`--help`)

Sortie simplifiée des aides intégrées:

Client `box`:
```
Usage: box [--cert <pem>] [--key <pem>] [--pre-share-key-identity <id>]
          [--pre-share-key <ascii>] [address] [port]
```

Serveur `boxd`:
```
Usage: boxd [--cert <pem>] [--key <pem>] [--pre-share-key-identity <id>]
          [--pre-share-key <ascii>]
```

### Exemple de bout-en-bout (PreShareKey)

Terminal 1 — serveur:
```bash
./build/boxd \
  --pre-share-key-identity box-client \
  --pre-share-key secretpsk
```

Terminal 2 — client:
```bash
./build/box \
  --pre-share-key-identity box-client \
  --pre-share-key secretpsk \
  127.0.0.1 12567
```

Observation attendue (logs):
- le serveur reçoit un datagramme initial, effectue le handshake DTLS, envoie un HELLO applicatif, puis répond PONG aux PINGs.
- le client réalise le handshake DTLS, affiche le HELLO du serveur, envoie un PING et affiche le PONG.

### Exemple de bout-en-bout (Certificats)

Terminal 1 — serveur:
```bash
./build/boxd --cert server.pem --key server.key
```

Terminal 2 — client:
```bash
./build/box --cert client.pem --key client.key 127.0.0.1 12567
```

Remarques:
- La configuration actuelle n’active pas la vérification X.509 (pas de chaîne CA/`SSL_VERIFY_PEER`). Pour un usage réel, charger une autorité (CA) et activer la vérification côté client (et idéalement côté serveur si mTLS requis).

## Vérification des certificats (client)

En mode certificats, le client vérifie par défaut le pair (côté OpenSSL) en utilisant:

- Les variables d’environnement optionnelles suivantes:
  - `BOX_CA_FILE`: chemin d’un fichier PEM contenant l’autorité de confiance (CA)
  - `BOX_CA_PATH`: répertoire de CAs (format OpenSSL)
  - `BOX_EXPECTED_HOST`: nom d’hôte attendu (vérification SAN/CN)
- Sinon, les chemins de confiance par défaut d’OpenSSL (`SSL_CTX_set_default_verify_paths`).

Exemple:
```bash
export BOX_CA_FILE="$PWD/server.pem"   # server.pem autosigné sert de CA de confiance
export BOX_EXPECTED_HOST=boxd
./build/box --cert client.pem --key client.key 127.0.0.1 12567
```

## Conventions

Ce dépôt suit une convention de nommage pour la bibliothèque "BoxFoundation" afin de garder une correspondance claire entre composants, fichiers et en-têtes publics.

- Fichiers et en-têtes: préfixe `BF` pour les composants BoxFoundation.
  - Exemples: `BFCommon`, `BFSocket`, `BFUdp`, `BFUdpClient`, `BFUdpServer`, `BFDtls`, `BFBoxProtocol`.
  - Mapping fichiers:
    - `include/box/BFCommon.h` ↔ `src/lib/BFCommon.c`
    - `include/box/BFSocket.h` ↔ `src/lib/BFSocket.c`
    - `include/box/BFUdp.h` ↔ `src/lib/BFUdp.c`
    - `include/box/BFUdpClient.h` ↔ `src/lib/BFUdpClient.c`
    - `include/box/BFUdpServer.h` ↔ `src/lib/BFUdpServer.c`
    - `include/box/BFDtls.h` ↔ `src/lib/BFDtlsOpenSSL.c`
    - `include/box/BFBoxProtocol.h` ↔ `src/lib/BFBoxProtocol.c`

- Tests: utiliser le préfixe `test_` suivi du nom du composant.
  - Exemple: `test/test_BFBoxProtocol.c` avec la cible CMake `test_BFBoxProtocol`.

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

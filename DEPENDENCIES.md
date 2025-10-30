Dependencies
============

Box se construit exclusivement avec Swift 6.2 et SwiftPM. Cette page récapitule les dépendances nécessaires (ou optionnelles) pour le développement et l’exécution.

## Prérequis obligatoires
- **Swift 6.2** (ou plus récent). Recommandation : installer via [Swiftly](https://www.swift.org/install/linux/#swiftly) :
  ```bash
  curl -sSf https://download.swift.org/swiftly/install.sh | bash
  swiftly install 6.2.0
  swiftly use 6.2.0
  ```
  Alternatives : paquets officiels Apple (macOS) ou archive `swift-6.2-RELEASE` pour Linux.
- **SwiftPM** (inclus dans la toolchain Swift).
- **Git**, **bash**, **zsh** (utilisés par la CLI Codex et certains scripts utilitaires).
- **IPv6 natif** recommandé sur la machine hôte (indispensable pour valider la topologie root resolver).

## Dépendances SwiftPM
Résolues automatiquement via `Package.swift` :
- [`swift-argument-parser`](https://github.com/apple/swift-argument-parser)
- [`swift-log`](https://github.com/apple/swift-log)
- [`swift-nio`](https://github.com/apple/swift-nio)
- [`Puppy`](https://github.com/sushichop/Puppy) (backend de journalisation)

## Dépendances optionnelles
- **libsodium** : requis pour la phase S4 (Noise/XChaCha). Installer via le gestionnaire de paquets de votre distribution (`apt install libsodium-dev`, `brew install libsodium`, etc.). Tant que le transport chiffré n’est pas activé, la binaire peut fonctionner sans.
- **swift-format** : recommandé pour formater le code (`brew install swift-format` ou via Swift toolchain).
- **Docker** : utile pour reproduire un environnement propre (voir `Dockerfile.dev`).

## Installation rapide par plateforme

### macOS (14+)
```bash
brew install swiftly libsodium swift-format
swiftly install 6.2.0
swift build --product box
swift test --parallel
```

### Ubuntu 24.04/25.04
```bash
sudo apt update
sudo apt install -y clang lld pkg-config libsodium-dev curl git
curl -sSf https://download.swift.org/swiftly/install.sh | bash
swiftly install 6.2.0
swift build --product box
swift test --parallel
```

### Windows (préparation)
Le port Swift Windows n’est pas encore validé pour Box, mais le workflow cible :
- Installation Swift toolchain officielle (`swift-6.0.2-RELEASE-windows10` ou ultérieur).
- libsodium via vcpkg (`vcpkg install libsodium:x64-windows`).
- L’exécutable conserve le socket admin `\\.\pipe\boxd-admin` (à implémenter). Tests Windows suivront la migration Swift.

## Commandes utiles
```bash
swift run box --help
swift run box --server --enable-port-mapping
swift run box admin status
swift run box admin nat-probe --gateway <ipv4>
```

## Environnements recommandés
- **Développement local** : macOS ou Linux avec Swift 6.2 installé via Swiftly. Prévoir une machine secondaire (ou VM) pour jouer un rôle de client pendant les tests de résolution.
- **Serveur racine de test** : VPS OVH VPS‑2/3 (Ubuntu) avec IPv6 statique. Cloner le dépôt, installer Swift, lancer `swift run box --server`.
- **CI** : GitHub Actions installe Swift 6.2 via Swiftly, puis exécute `swift build`/`swift test --parallel`. Aucun paquet C/CMake n’est requis.

## Ce qui a été retiré
- CMake, Make, Ninja, les scripts `scripts/*.sh` et tous les modules C historiques. Ne les réintroduisez pas.
- Les dépendances OpenSSL/DTLS ne sont plus nécessaires. Toute crypto future passera par libsodium + Noise.

Pour plus de détails fonctionnels, consultez `README.md`, `DEVELOPMENT_STRATEGY.md` et `SPECS.md`.

Android Notes
=============

Le port historique Android reposait sur l’implémentation C (JNI + CMake). Cette base ayant été supprimée, les instructions précédentes ne s’appliquent plus.

### État actuel
- Aucune cible Android n’est disponible dans la build Swift.
- Les futures itérations prévoiront un client mobile basé sur Swift (Swift 6.2 + SwiftNIO via Swift Android toolchain) ou via Kotlin/Swift interop.

### Backlog
- Préparer la génération d’un SDK Swift (ou gRPC) pour les applications mobiles.
- Définir la stratégie de packaging (SwiftPM cross-compilé, ou bibliothèque Kotlin utilisant une passerelle UDP).
- Ajouter des tests d’intégration spécifiques une fois la solution retenue.

En attendant, se référer aux tâches `NEXT_STEPS.md` pour suivre la préparation mobile. Toute nouvelle contribution Android doit partir de la base Swift, sans réintroduire les anciens projets CMake.

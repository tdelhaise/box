## Certificats de test

Générez un certificat autosigné pour DTLS :
```bash
openssl req -x509 -newkey rsa:2048 -keyout server.key \
-out server.pem -days 365 -nodes -subj "/CN=boxd"
```

Utilisation du secret cookie en prod :

Définis une variable d’environnement BOX_COOKIE_SECRET (32+ chars aléatoires) pour des cookies stables (sinon un secret aléatoire sera généré à chaque lancement).
```bash
export BOX_COOKIE_SECRET="$(openssl rand -hex 32)"
./boxd
```

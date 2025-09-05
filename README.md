## Certificats de test

Générez un certificat autosigné pour DTLS :
```bash
openssl req -x509 -newkey rsa:2048 -keyout server.key \
-out server.pem -days 365 -nodes -subj "/CN=boxd"

#!/usr/bin/env bash
# pki.sh — PKI minimale (Root CA + Intermediate CA) + certs serveur/client
# Compatible Linux/macOS (OpenSSL 1.1+/3.x). Éditable via variables ci-dessous.

set -euo pipefail

# ============
# PARAMÈTRES À PERSONNALISER
# ============
# Racine du workspace PKI (sera créé si absent)
PKI_DIR="${PKI_DIR:-$(pwd)/pki}"

# Identité par défaut (modifiable à l'appel)
ORG="${ORG:-MyOrg}"
OU="${OU:-Security}"
COUNTRY="${COUNTRY:-FR}"
STATE="${STATE:-IDF}"
LOCALITY="${LOCALITY:-Paris}"

# Noms par défaut des autorités
ROOT_NAME="${ROOT_NAME:-MyRootCA}"
INT_NAME="${INT_NAME:-MyIntermediateCA}"

# Durées de validité (jours)
DAYS_ROOT="${DAYS_ROOT:-3650}"        # ~10 ans
DAYS_INT="${DAYS_INT:-1825}"          # ~5 ans
DAYS_SERVER="${DAYS_SERVER:-825}"     # ~27 mois (pratique)
DAYS_CLIENT="${DAYS_CLIENT:-825}"

# Tailles de clés RSA
ROOT_KEY_BITS="${ROOT_KEY_BITS:-4096}"
INT_KEY_BITS="${INT_KEY_BITS:-4096}"
END_ENTITY_KEY_BITS="${END_ENTITY_KEY_BITS:-2048}"

# OpenSSL binaire (permet de pointer vers /opt/homebrew/opt/openssl@3/bin/openssl, etc.)
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

# ============
# ARBORESCENCE
# ============
ROOT_DIR="$PKI_DIR/root"
INT_DIR="$PKI_DIR/intermediate"
CONF_DIR="$PKI_DIR/conf"
OUT_DIR="$PKI_DIR/certs"

mkdir -p "$ROOT_DIR"/{certs,crl,newcerts,private,csr}
mkdir -p "$INT_DIR"/{certs,crl,newcerts,private,csr}
mkdir -p "$CONF_DIR" "$OUT_DIR"/{server,client}

chmod 700 "$ROOT_DIR/private" "$INT_DIR/private"

: > "$ROOT_DIR/index.txt" || true
: > "$INT_DIR/index.txt" || true
[ -f "$ROOT_DIR/serial" ] || echo 1000 > "$ROOT_DIR/serial"
[ -f "$INT_DIR/serial" ] || echo 2000 > "$INT_DIR/serial"
[ -f "$INT_DIR/crlnumber" ] || echo 3000 > "$INT_DIR/crlnumber"

ROOT_KEY="$ROOT_DIR/private/ca.key.pem"
ROOT_CERT="$ROOT_DIR/certs/ca.cert.pem"
INT_KEY="$INT_DIR/private/intermediate.key.pem"
INT_CSR="$INT_DIR/csr/intermediate.csr.pem"
INT_CERT="$INT_DIR/certs/intermediate.cert.pem"
CHAIN_CERT="$INT_DIR/certs/ca-chain.cert.pem"
ROOT_CNF="$CONF_DIR/root.cnf"
INT_CNF="$CONF_DIR/intermediate.cnf"

# ============
# CONFIG OPENSSL (root.cnf & intermediate.cnf)
# ============
write_root_cnf() {
cat > "$ROOT_CNF" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $ROOT_DIR
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/ca.key.pem
certificate       = \$dir/certs/ca.cert.pem
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = $DAYS_ROOT
preserve          = no
policy            = policy_strict
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/ca.crl.pem
default_crl_days  = 30

[ policy_strict ]
countryName             = supplied
stateOrProvinceName     = optional
organizationName        = supplied
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = $ROOT_KEY_BITS
distinguished_name  = req_distinguished_name
string_mask         = utf8only
x509_extensions     = v3_ca
default_md          = sha256
prompt              = no

[ req_distinguished_name ]
C  = $COUNTRY
ST = $STATE
L  = $LOCALITY
O  = $ORG
OU = $OU
CN = $ROOT_NAME

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:1
keyUsage = critical, keyCertSign, cRLSign
EOF
}

write_intermediate_cnf() {
cat > "$INT_CNF" <<EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $INT_DIR
certs             = \$dir/certs
crl_dir           = \$dir/crl
new_certs_dir     = \$dir/newcerts
database          = \$dir/index.txt
serial            = \$dir/serial
private_key       = \$dir/private/intermediate.key.pem
certificate       = \$dir/certs/intermediate.cert.pem
default_md        = sha256
name_opt          = ca_default
cert_opt          = ca_default
default_days      = $DAYS_INT
preserve          = no
policy            = policy_loose
crlnumber         = \$dir/crlnumber
crl               = \$dir/crl/intermediate.crl.pem
default_crl_days  = 30

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = supplied
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ req ]
default_bits        = $INT_KEY_BITS
distinguished_name  = req_distinguished_name
string_mask         = utf8only
x509_extensions     = v3_intermediate_ca
default_md          = sha256
prompt              = no

[ req_distinguished_name ]
O  = $ORG
OU = $OU
CN = $INT_NAME

[ v3_intermediate_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign

# Extensions dispo pour signer des EE certs
[ usr_cert ]
basicConstraints = CA:false
nsCertType = client, email
nsComment = "OpenSSL Generated Client Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth

[ server_cert ]
basicConstraints = CA:false
nsCertType = server
nsComment = "OpenSSL Generated Server Certificate"
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[ ocsp ]
basicConstraints = CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = OCSPSigning
EOF
}

# ============
# INIT CA RACINE
# ============
init_root() {
  echo "==> Initialisation CA Racine"
  write_root_cnf
  if [ ! -f "$ROOT_KEY" ]; then
    $OPENSSL_BIN genrsa -out "$ROOT_KEY" "$ROOT_KEY_BITS"
    chmod 400 "$ROOT_KEY"
  fi
  if [ ! -f "$ROOT_CERT" ]; then
    $OPENSSL_BIN req -config "$ROOT_CNF" -key "$ROOT_KEY" -new -x509 \
      -days "$DAYS_ROOT" -sha256 -extensions v3_ca -out "$ROOT_CERT"
    chmod 444 "$ROOT_CERT"
  fi
  echo "Racine OK: $ROOT_CERT"
}

# ============
# INIT CA INTERMÉDIAIRE
# ============
init_intermediate() {
  echo "==> Initialisation CA Intermédiaire"
  write_intermediate_cnf
  if [ ! -f "$INT_KEY" ]; then
    $OPENSSL_BIN genrsa -out "$INT_KEY" "$INT_KEY_BITS"
    chmod 400 "$INT_KEY"
  fi
  if [ ! -f "$INT_CSR" ]; then
    $OPENSSL_BIN req -config "$INT_CNF" -new -key "$INT_KEY" -out "$INT_CSR"
  fi
  if [ ! -f "$INT_CERT" ]; then
    $OPENSSL_BIN ca -batch -config "$ROOT_CNF" \
      -extensions v3_intermediate_ca \
      -days "$DAYS_INT" -notext -md sha256 \
      -in "$INT_CSR" -out "$INT_CERT"
    chmod 444 "$INT_CERT"
  fi
  cat "$INT_CERT" "$ROOT_CERT" > "$CHAIN_CERT"
  chmod 444 "$CHAIN_CERT"
  echo "Intermédiaire OK: $INT_CERT"
  echo "Chaîne: $CHAIN_CERT"
}

# ============
# CERTIFICAT SERVEUR
# Args: name [SANs]
#   name: label (ex: boxd)
#   SANs: "DNS:boxd.local,IP:127.0.0.1" (facultatif)
# ============
gen_server_cert() {
  local name="${1:-server}"
  local sans="${2:-DNS:${name}.local}"
  local key="$OUT_DIR/server/${name}.key.pem"
  local csr="$OUT_DIR/server/${name}.csr.pem"
  local crt="$OUT_DIR/server/${name}.cert.pem"

  mkdir -p "$OUT_DIR/server"

  echo "==> Génération certificat serveur: $name"
  $OPENSSL_BIN genrsa -out "$key" "$END_ENTITY_KEY_BITS"
  chmod 400 "$key"

  # CSR avec CN=$name (tu peux adapter le DN ici si besoin)
  $OPENSSL_BIN req -new -key "$key" -out "$csr" -subj "/O=$ORG/OU=$OU/CN=$name"

  # Fichier d'extensions serveur (incluant SAN)
  local ext="$(mktemp)"
  cat > "$ext" <<EOF
subjectAltName = $sans
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

  # Signature par l'intermédiaire
  $OPENSSL_BIN x509 -req -in "$csr" \
    -CA "$INT_CERT" -CAkey "$INT_KEY" -CAcreateserial \
    -out "$crt" -days "$DAYS_SERVER" -sha256 \
    -extfile "$ext"

  rm -f "$ext"
  chmod 444 "$crt"

  echo "Certificat serveur: $crt"
  echo "Chaîne à présenter côté serveur: $crt  +  $INT_CERT"
  echo "(Le client doit faire confiance à la racine: $ROOT_CERT)"
}

# ============
# CERTIFICAT CLIENT
# Args: name
# ============
gen_client_cert() {
  local name="${1:-client}"
  local key="$OUT_DIR/client/${name}.key.pem"
  local csr="$OUT_DIR/client/${name}.csr.pem"
  local crt="$OUT_DIR/client/${name}.cert.pem"

  mkdir -p "$OUT_DIR/client"

  echo "==> Génération certificat client: $name"
  $OPENSSL_BIN genrsa -out "$key" "$END_ENTITY_KEY_BITS"
  chmod 400 "$key"

  $OPENSSL_BIN req -new -key "$key" -out "$csr" -subj "/O=$ORG/OU=$OU/CN=$name"

  # Ext client
  local ext="$(mktemp)"
  cat > "$ext" <<EOF
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF

  $OPENSSL_BIN x509 -req -in "$csr" \
    -CA "$INT_CERT" -CAkey "$INT_KEY" -CAcreateserial \
    -out "$crt" -days "$DAYS_CLIENT" -sha256 \
    -extfile "$ext"

  rm -f "$ext"
  chmod 444 "$crt"

  echo "Certificat client: $crt"
  echo "(Le serveur doit faire confiance à la chaîne intermédiaire+racin e)"
}

# ============
# RÉVOCATION + CRL
# Args: path/to/cert.pem
# ============
revoke_cert() {
  local cert="${1:?chemin du certificat à révoquer}"
  echo "==> Révocation: $cert"
  $OPENSSL_BIN ca -config "$INT_CNF" -revoke "$cert" -crl_reason keyCompromise
  gen_crl
}

gen_crl() {
  echo "==> Génération CRL intermédiaire"
  $OPENSSL_BIN ca -config "$INT_CNF" -gencrl -out "$INT_DIR/crl/intermediate.crl.pem"
  chmod 444 "$INT_DIR/crl/intermediate.crl.pem"
  echo "CRL: $INT_DIR/crl/intermediate.crl.pem"
}

# ============
# VÉRIFICATION CHAÎNE
# Args: path/to/cert.pem
# ============
verify_cert() {
  local cert="${1:?certificat à vérifier}"
  echo "==> Vérification de chaîne"
  $OPENSSL_BIN verify -CAfile "$ROOT_CERT" -untrusted "$INT_CERT" "$cert"
}

# ============
# USAGE
# ============
usage() {
  cat <<EOF
Usage:
  $0 init                    # crée CA root + CA intermédiaire (+ chain)
  $0 server <name> [SANs]    # ex: $0 server boxd "DNS:boxd.local,IP:127.0.0.1"
  $0 client <name>           # ex: $0 client alice
  $0 revoke <cert.pem>       # révoque un certificat (EE), met à jour la CRL
  $0 crl                     # regenerer la CRL intermédiaire
  $0 verify <cert.pem>       # vérifie la chaîne (root + intermediate)
  $0 print                   # affiche chemins et fichiers clés

Variables éditables (env ou en-tête du script):
  PKI_DIR, ORG, OU, COUNTRY, STATE, LOCALITY
  ROOT_NAME, INT_NAME
  DAYS_ROOT, DAYS_INT, DAYS_SERVER, DAYS_CLIENT
  ROOT_KEY_BITS, INT_KEY_BITS, END_ENTITY_KEY_BITS
  OPENSSL_BIN

Fichiers utiles:
  Root:
    Clé:   $ROOT_KEY
    Cert:  $ROOT_CERT
  Intermediate:
    Clé:   $INT_KEY
    Cert:  $INT_CERT
    Chaîne: $CHAIN_CERT
  Sorties EE: $OUT_DIR/server  et  $OUT_DIR/client
EOF
}

# ============
# MAIN
# ============
cmd="${1:-}"
case "$cmd" in
  init)
    init_root
    init_intermediate
    ;;
  server)
    shift
    gen_server_cert "${1:-server}" "${2:-}"
    ;;
  client)
    shift
    gen_client_cert "${1:-client}"
    ;;
  revoke)
    shift
    revoke_cert "${1:?cert.pem requis}"
    ;;
  crl)
    gen_crl
    ;;
  verify)
    shift
    verify_cert "${1:?cert.pem requis}"
    ;;
  print)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac


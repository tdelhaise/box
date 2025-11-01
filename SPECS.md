Box Project Specification

1. Overview

1.1 Goals

Box provides a secure, user-owned service for storing and exchanging private information (documents, photos, IDs, messages, audio, etc.).
Unlike traditional cloud offerings, Box is designed to run on user-controlled hardware on a home or personally managed network
(e.g., a Raspberry Pi or repurposed small PC with sufficient storage). Users know where their data resides and control who can access it.

1.2 Non‑Goals

- Dependence on centralized Internet services (DNS, hosted auth, third-party identity) is explicitly avoided.
- Exposing personal information (name, email, phone) through public identifiers is not allowed.
- Relying on TCP-only or HTTP-based protocols is out of scope; the protocol is designed for UDP/IPv4 and UDP/IPv6.

1.3 Guiding Principles

- Security first: confidentiality, integrity, authenticity for data in motion; optional encryption at rest.
- Resilience: continue to function even if DNS or common Internet services fail; rely only on IP routing.
- Simplicity: minimal components, well-defined binary protocol, predictable CLI and daemon behavior.

2. Terminology

- User UUID: A stable, opaque UUID that uniquely identifies a user. It carries no personal information.
- Node UUID: A stable, opaque UUID that uniquely identifies a Box node (a running instance of boxd).
- Box Node: A device running the Box daemon (`boxd`) reachable via UDP (IPv4/IPv6).
- Location Service: A Box protocol service that maps UUIDs to reachable IP endpoints and status metadata.
- Queue: A named logical destination on a server where objects (messages/files) are stored (e.g., `/message`, `/photos`).

3. Components

- `box` (CLI): Client that sends requests to Box nodes. Supports sending/receiving data and managing queues.
- `boxd` (daemon): Background server that listens for inbound UDP requests, authenticates clients, and stores/retrieves objects.
- Location Service (LS): A Box-protocol endpoint embedded in `boxd` that registers and resolves node locations. It is strictly self‑hosted per user; no external dependency.

4. High‑Level Architecture

- Transport: UDP over IPv6 by default, IPv4 supported. Single well-known port configurable per node.
- Discovery: Clients use the self‑hosted Location Service on the target user’s node(s) to resolve a User UUID ⇒ Node endpoints (IP, UDP port) and metadata. At least one bootstrap endpoint (IP:port) must be shared out‑of‑band.
- Identity: Users and nodes are identified by UUIDs. Cryptographic keys bind to these identities (see Security).
- Authorization: Servers only accept requests from clients that appear in the Location Service as registered for the relevant User UUID.
- Storage: Server persists objects per queue, keyed by metadata (time, content digest, optional IDs). Storage is pluggable (filesystem by default).
  - Filesystem default: `~/.box/queues/<queue_name>/` with a mandatory `INBOX` queue created at first boot; server startup aborts if `INBOX` cannot be provisioned.

4.1 Daemon Execution Model

- `boxd` runs four cooperative threads: the main thread owns the StorageManager and LocationManager runloop; a network input thread receives datagrams, performs framing/Noise validation, and posts semantic events to the main loop; a network output thread serializes transmission requests; and an admin thread services the Unix-domain control socket.
- All four threads execute BFRunloop instances so work is posted asynchronously; the main loop is the sole owner of stateful subsystems (storage, ACLs, configuration) to keep locking narrow.
- Near-term follow-up: finish wiring the existing BFRunloop scaffolding so the main, network input, and network output runloops are started during daemon boot and exchange events for simple UDP v1 traffic.
- Mid-term follow-up: extend BFRunloop with per-platform reactor backends (kqueue on BSD/macOS, epoll on Linux, IOCP or WSAPoll on Windows) so readiness notifications replace blocking I/O without introducing third-party dependencies.

5. Security and Identity

5.1 Identities

- Every user has a User UUID.
- Every node has a Node UUID.
- Each node holds a long-term identity key pair (e.g., Ed25519 for signatures) bound to its Node UUID.

5.2 Key Distribution

- The Location Service returns a node’s public identity key along with its IP/port, enabling clients to authenticate handshakes.
- Users share their User UUID out-of-band with trusted peers. The User UUID does not reveal personal data.

5.3 Handshake and Session

- All request bodies are protected with authenticated encryption (AEAD) using XChaCha20‑Poly1305.
- Session keys are established using an authenticated key exchange (Noise NK/IK over UDP using X25519 for ECDH and Ed25519 for signatures). An AEAD layer uses XChaCha20‑Poly1305; helpers exist in the codebase and the transport integration is in progress.
Implementation Status (Crypto/Noise)
- The current codebase includes AEAD helpers (XChaCha20‑Poly1305) and a preliminary Noise transport framing:
  - Frame: ASCII `NZ`, version byte `0x01`, reserved byte `0x00`, followed by a 24‑byte nonce and the AEAD ciphertext of the payload with the 4‑byte header as associated data.
  - Nonce: formed from a 16‑byte salt (per peer, constant) and an 8‑byte big‑endian counter (monotonic per direction).
  - Replay protection: receivers enforce salt consistency and reject frames that are too old or already seen using a 64‑entry sliding window referenced to the highest accepted counter.
  - Temporary keying: a pre‑shared key (PSK) is used to derive the AEAD key until the Noise NK/IK handshake is implemented.
  - A debug‑only hook exists to re‑send the last encrypted frame for replay testing.
Scaffold NK/IK (current):
- Pattern selection: `NK` (initiator knows responder static) and `IK` (both know statics) are
  recognized as scaffolding modes. Full message patterns are not implemented yet.
- Transcript binding: a BLAKE2b transcript hash commits to a label `box/noise/scaffold/v1`, the
  selected pattern, an optional prologue, and any configured static public keys (server and/or
  client). This transcript hash is stored per connection for future binding and logging.
- Session key derivation: the AEAD session key is derived as a BLAKE2b keyed hash over the
  transcript hash. The key for the hash must be secret: either a pre‑shared key (PSK) or, in
  development mode, the client static private key (IK only). If no secret is configured, the
  Noise transport remains disabled.
- Identity binding: when present, the server static public key (NK/IK) and client static public
  key (IK) are mixed into the transcript and therefore bound to the derived session key. This lays
  the groundwork for authenticating identities once message patterns and signatures are added.
Future work:
- Replace PSK with proper NK/IK handshake to derive session keys, bind identities, and sign transcripts. Extend the replay window strategy and document error codes and limits.
- Replay protection is enforced using nonces and a sliding window; servers reject stale or duplicate counters per peer (see 5.3.1).

5.3.1 Replay Protection Details

- Nonce construction: 24 bytes where the first 16 bytes are a per‑direction salt (randomly chosen
  by the sender for the lifetime of the connection), and the last 8 bytes are a big‑endian
  monotonic counter starting at 1.
- Salt consistency: The receiver records the first observed salt from a peer and rejects any frame
  with a different salt for that peer.
- Sliding window: The receiver tracks the highest accepted counter and a 64‑bit bitmap of the last
  64 counters. On successful decryption, counters higher than the current maximum advance the
  window; older counters within the window set the corresponding bit. Frames older than the 64‑slot
  window or those with already set bits are rejected as stale or replayed.

5.4 Authorization

- The server validates that the presenting client User UUID and Node UUID are currently registered (and not revoked) in the Location Service.
- Per‑queue ACLs are supported: allow/deny by User UUID and/or Node UUID; optional capabilities (put/get/delete).

6. Location Service (LS)

6.1 Purpose

- Resolve: User UUID ⇒ list of Node records for that user.
- Register: A node updates its reachable addresses and metadata.
- Status: Provide presence metadata to aid client selection and server admission control.

6.2 Node Record

- node_uuid (UUID, required)
- user_uuid (UUID, required)
- ip (IPv6 or IPv4), port (UDP), protocol version(s)
- node_public_key (identity)
- online (bool), since (timestamp), last_seen (timestamp)
- optional geo: latitude, longitude, altitude
- optional tags: free‑form key/value strings

6.3 Deployment

- The LS is self‑hosted by the user and embedded in each `boxd` instance belonging to that user. There is no dependency on any external computer or service.
- Peers must know at least one bootstrap IP:port for the target user (shared out‑of‑band) to query LS and initiate secure communication.
- The LS persists and consumes state through standard queues (see Standard Queues) to remain operable without external databases.
- Global resilience relies on a small federation of Box “root resolvers”. Each deployment MUST provision at least three root servers with static IPv6 addresses known a priori (configured locally on every node/client). No DNS lookup is required or assumed.
- Root resolvers accept per-minute refreshes from every online BoxServer, validate the signed payload, and update the `whoswho` queue atomically by overwriting `<uuid>.json`. If a node misses two consecutive refresh intervals (>120 s), resolvers mark it stale so clients can fall back to other nodes.
- Client resolution first targets the closest root resolver; on timeout or stale data it MUST iterate through the remaining addresses in order. Implementations should randomise the starting resolver to spread load.
- Server-to-server refreshes MUST be mutually authenticated (Noise/libsodium handshake) so that a malicious intermediary cannot pose as a trusted node; resolvers reject unsigned or mismatched identity updates and SHOULD log the attempt for operators.

6.4 Bootstrap Guide (Out‑of‑Band Exchange)

- What to share:
  - The target user’s `User UUID`.
  - At least one reachable `IP:port` for a node hosting that user’s embedded LS (`boxd`). Prefer IPv6 global addresses.
  - Optional but recommended: the server identity key fingerprint (Ed25519 public key, hex; e.g., SHA‑256 of raw key).

- Recommended bundle formats:
  - URI: `box://<user_uuid>@<ip_or_[ipv6]>:<port>`
    - Example: `box://507FA643-A2A6-47AF-A09E-E235E9727332@[2001:db8::10]:9988`
  - JSON (shareable via QR/text):
    {
      "user_uuid": "507FA643-A2A6-47AF-A09E-E235E9727332",
      "bootstrap": [
        {"ip": "2001:db8::10", "port": 9988},
        {"ip": "203.0.113.20", "port": 9988}
      ],
      "fp": "ed25519:8c1f...ab42"
    }

- Client import/usage:
  - Enter the bundle into `box` configuration or supply the URI directly to the first command.
  - The client sends HELLO to the bootstrap endpoint, verifies the server identity key (matches fingerprint if provided), then queries LS to learn all current nodes for the user.

- Address changes:
  - If IP/port changes, owner shares a new bootstrap bundle OOB or pushes an update through existing authenticated Box channels.
  - Keep multiple bootstrap endpoints to improve reachability.

- NAT/Firewall notes:
  - Prefer IPv6 with globally routable addresses. If using IPv4, configure port forwarding on the gateway for the UDP port used by `boxd`. Un module automatique PCP/NAT-PMP/UPnP (opt-in) est prévu pour demander l’ouverture du port côté routeur lorsqu’il est compatible.
  - Ensure firewall allows inbound UDP on the configured port.

6.5 Bootstrap URI Specification

- Canonical scheme: `box://`
- Purpose: Convey a user identifier and at least one initial reachable endpoint for that user’s node/LS, optionally with a key fingerprint.
- General form:
  - `box://<user_uuid>@<host>:<port>`
  - `<host>` accepts `IPv4`, `hostname`, or IPv6 in brackets `[IPv6]`.
- Optional query parameters for metadata: `?fp=<fingerprint>&node=<node_uuid>&v=<proto_version>`

- ABNF (informative):
  box-uri   = "box://" user-uuid [ "@" host ":" port ] [ "?" params ]
  user-uuid = 8HEXDIG "-" 4HEXDIG "-" 4HEXDIG "-" 4HEXDIG "-" 12HEXDIG
  node-uuid = user-uuid
  host      = IPv6address / IPv4address / reg-name
  port      = 1*DIGIT
  params    = param *( "&" param )
  param     = ( "fp=" fingerprint ) / ( "node=" node-uuid ) / ( "v=" 1*DIGIT ) / ( "proto=" "udp" )
  fingerprint = alg ":" 1*HEXDIG
  alg       = "ed25519" / "sha256"

- Fingerprint
  - Preferred: `ed25519:<hex>` the 32‑byte raw Ed25519 public key in lowercase hex.
  - Accepted: `sha256:<hex>` the SHA‑256 of the raw Ed25519 public key (lowercase hex).

- Examples
  - `box://507FA643-A2A6-47AF-A09E-E235E9727332@[2001:db8::10]:9988`
  - `box://507FA643-A2A6-47AF-A09E-E235E9727332@203.0.113.20:9988?fp=ed25519:8c1f...ab42`
  - `box://507FA643-A2A6-47AF-A09E-E235E9727332?fp=sha256:3a7b...99c1` (endpoint inferred from context)

6.6 Location Service API (Informative JSON Shapes)

- Transport: Payloads are carried over the Box protocol (UDP) and protected by session encryption after HELLO. JSON here illustrates field semantics; CBOR/JSON encodings are acceptable.
- Authentication: Requests are authenticated at the transport layer; sensitive fields may be signed by the node identity key where indicated.
- Implementation note (Swift runtime): records are serialised as JSON and persisted in la file permanente `whoswho/` via le `LocationServiceCoordinator`, en réutilisant le même builder que les réponses `box admin status|stats` afin de garder `addresses[]` et `connectivity` cohérents sur toutes les surfaces.

Register/Update Node
- Request
  {
    "op": "register",
    "record": {
      "user_uuid": "507FA643-A2A6-47AF-A09E-E235E9727332",
      "node_uuid": "776BA464-BA07-4B6D-B102-11D5D9917C6F",
      "ip": "2001:db8::10",
      "port": 9988,
      "node_public_key": "ed25519:8c1f...ab42",
      "online": true,
      "since": 1736712345123,
      "last_seen": 1736712389456,
      "tags": {"role": "home", "ver": "1"}
    },
    "sig": "ed25519:..."  
}

6.7 Locate Storage Semantics

- Every entry exposed by `locate` is persisted as a JSON document under `~/.box/queues/whoswho/<uuid>.json`.
- File naming mirrors the UUID of the subject: `node_uuid.json` for node records, `user_uuid.json` for user aggregates.
- The queue `whoswho` is declared **permanent** (`server.permanent_queues`), meaning `GET`/`locate` never delete records.
- `locate` is implemented internally as a `GET` constrained to the `whoswho` queue. The runtime MUST reject attempts to locate from any other queue.
- `PUT /whoswho` replaces the full JSON payload atomically. The store keeps the newest record only; previous versions are discarded after successful write.
- Node records and user records embed a monotonically increasing `revision` (uint64) and `updated_at` (ISO 8601 UTC). Servers MUST refuse to overwrite a record with a lower revision to avoid stale data.
- When a node updates its user’s membership list, it MUST publish the user record immediately after the node record so readers never observe a dangling node UUID for more than one sync cycle.
- Clients attempting to `locate` SHOULD randomise the order of configured root servers and bail out after the first successful `PUT` frame is received.

6.8 Root Resolver Synchronisation (Noise)

- Transport
  - Synchronisation uses the Box clear-text protocol over UDP, upgraded with the Noise IK handshake (client = initiator, server = responder). No TLS/PKI is involved.
  - Messages are wrapped in the standard AEAD frames after the handshake, reusing the same framing code path as regular client/server traffic.
- Topology
  - Each root resolver maintains a list of its peers (`common.root_servers` excluding itself).
  - A background task wakes every 5–10 s, shuffles the peers, and attempts a sync session with each reachable peer.
- Message Flow (per peer)
  1. **HELLO/IK Noise**: Initiator authenticates using its static root identity key; the responder verifies against its allow-list of trusted root keys.
  2. **INDEX_EXCHANGE**: Initiator sends `{ "type": "index", "revision": globalRevision, "entries": [ {"uuid":…, "rev":…, "digest":…}, … ] }`.
  3. Responder compares with its local index and replies with the set of UUIDs that are newer or missing on each side (`need_push`, `need_pull`).
  4. Parties transfer missing records using `RECORD_PUSH { uuid, rev, payload }` frames; the receiver validates the signature and accepts only strictly newer revisions.
  5. Once both `need_*` sets are empty, the responder emits `SYNC_DONE` and both sides close the channel.
- Conflict Resolution
  - Records carry `revision`, `updated_at`, and `signature` (Noise static key of the owner). The highest `revision` wins; ties fall back to `updated_at`, then lexicographic order of the signing key.
  - If verification fails, the record is discarded and a `sync_warning` is logged.
  - Roots SHOULD persist an append-only journal of accepted revisions to speed up recovery after downtime.
- Failure Handling
  - If a peer is unreachable, the root retries on the next wake cycle and surfaces the issue via `box admin location-summary`.
  - After a root rejoins (cold start), it performs a full pull by advertising `revision = 0`; peers then stream all records.
  - Sync sessions are short-lived; if no progress is observed for 3 successive intervals, the connection is aborted and rescheduled.

6.9 Identity & Trust Establishment (Autorité décentralisée)

- **But** : fournir des garanties d’identité sans dépendre d’une PKI centralisée.
- **Identité primaire**
  - `box init-config` génère automatiquement une paire de clefs Ed25519 pour l’utilisateur (`user.identity.json`) et une paire pour le nœud (`node.identity.json`), stockées sous `~/.box/keys/` avec permissions 600.
  - Le CLI signe immédiatement la clef du nœud avec la clef utilisateur et dépose un lien croisé (le node contre-signe l’UUID utilisateur) afin d’établir la relation de confiance locale.
  - L’option `--rotate-identities` force la régénération des UUID et des clefs (commande interactive, avertissements sur la révocation nécessaire).
  - Une commande future `box register` publiera ces identités auprès des racines configurées (PUT signé sur `whoswho`).
  - Lorsqu’aucun `Box.plist` n’existe, `box init-config` demande si l’opérateur possède déjà un `user_uuid`. Si oui, il le saisit (ou l’indique via un futur drapeau `--user-uuid`) et la nouvelle machine ne crée qu’un `node_uuid`; sinon, un nouveau couple utilisateur/nœud est généré.
- **Attestation multi-canaux**
  1. **Présentation initiale** : l’utilisateur partage un paquet bootstrap (voir §6.4) comprenant UUIDs, fingerprints des clefs et, si possible, une preuve hors-ligne (QR code, carte papier, clef USB, etc.).
  2. **Contrôle visuel / social** : les pairs peuvent vérifier physiquement ou par visio que la personne associée à l’UUID possède bien le secret (ex : lecture d’un challenge, signature d’un texte imposé).
  3. **Web-of-Trust léger** : une identité peut être cosignée par d’autres utilisateurs via des certificats simples `{ signee_uuid, signer_uuid, signed_fingerprint, timestamp, scope }`. Ces attestations sont stockées dans `whoswho` sous `user_uuid-cert-<hash>.json` et synchronisées entre racines.
  4. **Challenge réseau** : lors du premier contact, le client envoie un défi aléatoire que le serveur signe avec sa clef statique. La signature est vérifiée contre la fingerprint reçue hors-bande ou via l’attestation WoT.
- **Révocation / rotation**
  - L’utilisateur publie un enregistrement `revocation` listant les fingerprints devenues invalides et signées par la clef actuellement de confiance.
  - En cas de compromission supposée, un canal hors-ligne (rencontre physique, appel vocal sécurisé) est fortement recommandé pour confirmer la nouvelle clef.
- **Ancrage temporel**
  - Chaque signature inclut `issued_at` et `expires_at`. Les racines refusent un document expiré et alertent le propriétaire.
  - Les horloges sont synchronisées via NTP ou par observation relative (drift max 5 min) pour éviter les rejets intempestifs.
- **Interopérabilité**
  - Aucune autorité externe n’est requise, mais rien n’empêche un groupe de confiance (collectif, entreprise) de publier un lot d’attestations signées pour ses membres.
  - Les clients peuvent choisir leur politique : exiger N cosignatures, ou bien accepter une seule signature si elle est issue d’un contact physique vérifié récemment.
- Response
  { "ok": true, "ts": 1736712390000 }

Resolve by User UUID
- Request
  { "op": "resolve", "user_uuid": "507FA643-A2A6-47AF-A09E-E235E9727332" }
- Response
  {
    "ok": true,
    "nodes": [
      {
        "node_uuid": "776BA464-BA07-4B6D-B102-11D5D9917C6F",
        "addresses": [
          {
            "ip": "2001:db8::10",
            "port": 9988,
            "scope": "global",
            "source": "probe"
          },
          {
            "ip": "198.51.100.10",
            "port": 12567,
            "scope": "global",
            "source": "manual"
          }
        ],
        "node_public_key": "ed25519:8c1f...ab42",
        "online": true,
        "since": 1736712345123,
        "last_seen": 1736712389456,
        "connectivity": {
          "has_global_ipv6": true,
          "global_ipv6": ["2001:db8::10"],
          "port_mapping": {
            "enabled": true,
            "origin": "default",
            "external_ipv4": "198.51.100.10",
            "external_port": 12567,
            "status": "ok",
            "peer": {
              "status": "ok",
              "lifetime_seconds": 3600,
              "last_updated": 1736712389000
            },
            "reachability": {
              "status": "ok",
              "last_checked": 1736712389456,
              "round_trip_ms": 42
            }
          }
        }
      }
    ]
  }

Resolve by Node UUID
- Request
  { "op": "resolve", "node_uuid": "776BA464-BA07-4B6D-B102-11D5D9917C6F" }
- Response
  { "ok": true, "node": { /* same shape as in nodes[] above */ } }

6.10 Commande `box register`

- **Objectif** : publier (ou republier) les enregistrements node/user vers l’ensemble des racines configurées.
- **Invocation**
  - `box register [--path <Box.plist>] [--address <ip>] [--port <udp_port>] [--root host[:port]]...`
  - `--path` sélectionne un fichier de configuration explicite (par défaut `~/.box/Box.plist`).
  - `--address` / `--port` permettent d’annoncer une adresse publique précise lorsque l’autodétection n’est pas souhaitée.
  - `--root` surcharge la liste des serveurs racines (`host[:port]`). Sans override, la commande utilise `common.root_servers`.
- **Pré-requis**
  - `init-config` doit avoir généré les identités Ed25519 et le lien croisé `identity-links.json`.
  - `common.root_servers` contient au moins une entrée (init-config insère par défaut `box1` et `box2`).
  - La machine connaît le port UDP qu’elle souhaite annoncer (priorité à `server.externalPort` puis `server.port`, sinon 12567).
- **Processus**
  1. Chargement du PLIST et des paires de clefs (`user.identity.json`, `node.identity.json`).
  2. Construction du `LocationServiceNodeRecord` : adresses manuelles (`--address`), adresse externe config (`server.external_address`), clé publique format `ed25519:<hex>`, métadonnées port mapping.
  3. Construction du `LocationServiceUserRecord` à partir de l’enregistrement local (`whoswho/<user_uuid>.json`) en conservant les nœuds existants et en ajoutant le nœud courant.
  4. Encodage JSON (`sortedKeys`) et envoi, pour chaque racine, de deux requêtes `PUT whoswho` via le client UDP (`BoxClientAction.put`).
  5. Persistence locale du nouvel enregistrement utilisateur dans `~/.box/queues/whoswho/<user_uuid>.json` pour aider les publications futures hors-ligne.
- **Comportement en erreur**
  - Si une racine est injoignable, la commande continue avec les autres mais échoue en sortie (code ≠ 0) en listant les endpoints défaillants.
  - Les messages d’information du client (`STATUS response`, `PUT acknowledgement`) sont émis sur stderr pour faciliter le débogage.
- **Évolutions prévues (0.4.x)**
  - Ajout de champs `revision` / `signature` pour verrouiller la cohérence, synchronisation automatique entre racines, publication atomique user/node.

6.11 Location Service CBOR CDDL (Informative)

- The following CDDL sketches the CBOR encoding for LS messages. Field names mirror the JSON forms above.

  ; Primitives
  uuid = b16 .size 16         ; 16-byte UUID (binary)
  tstr-nonempty = tstr .regexp ".+" ; non-empty text
  port = 0..65535

  ; Node record as used by LS
  node-record = {
    "user_uuid": uuid,
    "node_uuid": uuid,
    "addresses": [
      {
        "ip": tstr-nonempty,
        "port": port,
        "scope": "global" / "lan" / "loopback",
        "source": "probe" / "config" / "manual"
      }
    ],
    "node_public_key": tstr-nonempty, ; e.g., "ed25519:" + hex
    "online": bool,
    "since": uint,
    "last_seen": uint,
    "connectivity": {
      "has_global_ipv6": bool,
      "global_ipv6": [* tstr-nonempty],
      ? "ipv6_probe_error": tstr-nonempty,
      "port_mapping": {
        "enabled": bool,
        "origin": tstr-nonempty,
        ? "external_ipv4": tstr-nonempty,
        ? "external_port": port,
        ? "status": tstr-nonempty,
        ? "error": tstr-nonempty,
        ? "error_code": tstr-nonempty,
        ? "peer": {
          "status": tstr-nonempty,
          ? "lifetime_seconds": uint,
          ? "last_updated": uint,
          ? "error": tstr-nonempty
        },
        ? "reachability": {
          "status": tstr-nonempty,
          ? "last_checked": uint,
          ? "round_trip_ms": uint,
          ? "error": tstr-nonempty
        }
      }
    },
    ? "tags": { * tstr => tstr }
  }

  ; Register/Update request (signed at transport layer; optional explicit signature field)
  ls-register = {
    "op": "register",
    "record": node-record,
    ? "sig": tstr
  }

  ; Generic resolve requests
  ls-resolve-user = { "op": "resolve", "user_uuid": uuid }
  ls-resolve-node = { "op": "resolve", "node_uuid": uuid }

  ; Responses
  ls-ok = true
  ls-ts = uint

  ls-register-resp = { "ok": ls-ok, "ts": ls-ts }

  ls-resolve-user-resp = {
    "ok": ls-ok,
    "nodes": [* node-record]
  }

  ls-resolve-node-resp = {
    "ok": ls-ok,
    "node": node-record
  }

7. CLI Smoke Path (Noise Transport)

- Purpose: Exercise the Noise transport framing over UDP with a simple ping/pong exchange using the
  scaffolded key derivation and replay protection.
- Server (`boxd`):
  - Enable via CLI: `boxd --transport noise [--pre-share-key <ascii>]`
  - Or via la section `server` de `~/.box/Box.plist`:
    - `<key>transport</key><string>noise</string>` (général) ou `transport_status = noise` pour STATUS uniquement
    - Optionnel: `pre_share_key`, `noise_pattern` (`nk`|`ik`)
- Client (`box`):
  - `box <address> [port] --transport noise [--pre-share-key <ascii>]`
  - Optional environment: `BOX_NOISE_PATTERN=nk|ik`
- Flow:
  1) Client sends an initial clear UDP datagram so the server learns the client address.
  2) Both sides derive the session key from the configured secret and bound identities.
  3) Client sends an encrypted `ping`; server replies with encrypted `pong`.
  4) Optional replay test: in test builds, the client can retransmit the last frame; the server
     rejects it based on the sliding window.

6.12 Location Service CBOR Examples (Hex + Diagnostic)

Notes
- These examples illustrate one possible canonical CBOR encoding. Implementations do not need to match byte-for-byte as long as they produce valid messages conforming to the schema. Byte strings for UUIDs are 16 bytes; values below are sample data.

Example A — ls-register (minimal, without tags)

Diagnostic notation
  {
    "op": "register",
    "record": {
      "user_uuid": h'000102030405060708090A0B0C0D0E0F',
      "node_uuid": h'F0E0D0C0B0A090807060504030201000',
      "addresses": [
        {
          "ip": "2001:db8::10",
          "port": 9988,
          "scope": "global",
          "source": "probe"
        }
      ],
      "node_public_key": "ed25519:00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
      "online": true,
      "since": 1,
      "last_seen": 2,
      "connectivity": {
        "has_global_ipv6": true,
        "global_ipv6": ["2001:db8::10"],
        "port_mapping": {
          "enabled": false,
          "origin": "default"
        }
      }
    }
  }

Exact hex (canonical CBOR, sorted map keys) — pending regeneration. The previous
encoding did not include the new `addresses` and `connectivity` maps. Re-run the
encoder once the schema stops evolving to publish an authoritative hex dump.

Example B — ls-resolve-user response (single node)

Diagnostic notation
  {
    "ok": true,
    "nodes": [
      {
        "user_uuid": h'000102030405060708090A0B0C0D0E0F',
        "node_uuid": h'F0E0D0C0B0A090807060504030201000',
        "addresses": [
          {
            "ip": "2001:db8::10",
            "port": 9988,
            "scope": "global",
            "source": "probe"
          }
        ],
        "node_public_key": "ed25519:00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
        "online": true,
        "since": 1,
        "last_seen": 2,
        "connectivity": {
          "has_global_ipv6": true,
          "global_ipv6": ["2001:db8::10"],
          "port_mapping": {
            "enabled": false,
            "origin": "default"
          }
        }
      }
    ]
  }

Exact hex (canonical CBOR, sorted map keys) — pending regeneration with the new
record shape. Ellipses (…) will continue to indicate trimmed string bodies for
brevity once a refreshed sample is committed.

7. Data Model

- Queue: A namespace under a user’s server for storing objects. Example queues: `/message`, `/photos`, `/ids`.
- Object: Arbitrary binary blob with metadata: content_type, size, timestamp, digest (SHA‑256), optional filename.
- Addressing: `<user_uuid>[@<node_uuid>]/<queue>` uniquely identifies a destination. If `@<node_uuid>` is omitted, the client picks a suitable node from LS.

7.1 Access Control Lists (ACLs)

- Every queue has an attached ACL. Effective permissions are the conjunction of global ACL and queue‑level ACL (both must allow).
- ACL entries may target User UUIDs and/or Node UUIDs with capabilities: put/get/delete/list.
- Default policy is deny‑by‑default unless explicitly allowed.

7.2 Standard Queues

- `whoswho` (content_type: `application/json`, permanent queue):
  - Purpose: Authoritative presence ledger for all online Box nodes and users. Each record lives in a single JSON file named `<uuid>.json` (no timestamp prefix) so a subsequent refresh replaces the same file in place.
  - Population rules:
    - Each online BoxServer pushes an update every 60 seconds containing its `node_uuid`, `user_uuid`, reachable IPv6 endpoints, advertised ports, last refresh timestamp, and owner UUID. The payload matches the `LocationServiceNodeRecord` schema used on the admin channel.
    - For every `user_uuid`, the root resolver stores a companion JSON file listing the active `node_uuid`s owned by that user (+ optional metadata as the protocol evolves).
    - Records are signed at the transport layer (Noise/libsodium milestone) so that resolvers can reject forged presence updates.
  - ACL: readable by authorized peers (including clients resolving remote nodes); writable by the owner’s nodes and by root resolvers that mirror the data; deletion restricted to owner/admin.

- `/location` (content_type: `application/cbor` or `application/json`):
  - Purpose: Publish optional geographic location per UUID.
  - Object schema (logical):
    - user_uuid (UUID) or node_uuid (UUID)
    - latitude (float), longitude (float), altitude (float, optional)
    - accuracy_m (optional float), timestamp
  - ACL: readable by authorized peers; writable by the owning user’s nodes or clients as allowed; delete restricted to owner/admin.
  - JSON example:
    {
      "user_uuid": "507FA643-A2A6-47AF-A09E-E235E9727332",
      "latitude": 48.8566,
      "longitude": 2.3522,
      "altitude": 35.0,
      "accuracy_m": 20.5,
      "timestamp": 1736712400123
    }
  - CBOR CDDL sketch (informative):
    location = {
      ? "user_uuid": uuid,
      ? "node_uuid": uuid,
      "latitude": float,
      "longitude": float,
      ? "altitude": float,
      ? "accuracy_m": float,
      "timestamp": uint
    }

8. CLI Usage

8.1 Examples

Send a message to a user:

  $ box sendTo 507FA643-A2A6-47AF-A09E-E235E9727332/message "Hello world"

Send a message to a specific node of that user:

  $ box sendTo 507FA643-A2A6-47AF-A09E-E235E9727332@776BA464-BA07-4B6D-B102-11D5D9917C6F/message "Hello world"

Send a photo file to a user:

  $ box sendTo 507FA643-A2A6-47AF-A09E-E235E9727332/photos /Users/John/Images/Earth.jpg

Send on behalf of a specific sender User UUID:

  $ box --sender 9B6DF823-6E22-4BAD-BB6E-77EC6F71AEF1 \
        sendTo 507FA643-A2A6-47AF-A09E-E235E9727332/photos /Users/John/Images/Earth.jpg

8.2 Command Surface (initial)

- `sendTo <addr>/<queue> <data_or_path>`: PUT an object (inline text or file path).
- `getFrom <addr>/<queue> [--latest|--id <digest>]`: GET latest or by digest.
- `list <addr>/<queue> [--limit N] [--since TS]`: SEARCH/List objects.
- `deleteFrom <addr>/<queue> --id <digest>`: DELETE an object.
- Common flags: `--sender <user_uuid>`, `--node <node_uuid>`, `--config <file>`, `--timeout <ms>`, `--ipv4|--ipv6`.
- `check connectivity [--enable-port-mapping] [--methods <list>] [--peer <addr>] [--json]`: Runs local/target connectivity diagnostics (see Connectivity Check CLI).

9. Wire Protocol

9.1 Framing

- All frames are big‑endian (network byte order).
- 1 byte: magic = 'B' (0x42)
- 1 byte: version (current: 1)
- 4 bytes: total_length of the remainder (uint32)
- 4 bytes: command (uint32): HELLO=1, PUT=2, GET=3, DELETE=4, STATUS=5, SEARCH=6, BYE=7
- 16 bytes: request_id (UUID) to corréler les réponses
- 16 bytes: node_id (UUID du nœud expéditeur)
- 16 bytes: user_id (UUID du user pour lequel l’action est effectuée)
- Remaining: command-specific payload (généralement chiffré via AEAD après la phase HELLO)

Note: Except for the initial HELLO exchange used to establish keys, payloads are AEAD‑encrypted. Command code may remain cleartext for routing.

9.2 Common Fields (where applicable)

- timestamp (uint64, ms since epoch)
- nonce (24 bytes for XChaCha20)
- user_uuid (16 bytes), node_uuid (16 bytes)
- signature (Ed25519, 64 bytes) over a canonical transcript portion (defined per command)

9.3 Commands

HELLO (1)
- Client → Server:
  - user_uuid, node_uuid, client_identity_pubkey, timestamp, nonce, client_supported_versions
  - optional LS proof (server may verify client is registered)
- Server → Client:
  - server_identity_pubkey, server_supported_versions, server_nonce
  - optional challenge; both sides derive session keys

PUT (2)
- Req: queue_path_len (uint16), queue_path (UTF‑8), content_type_len (uint16), content_type, payload_len (uint32/uint64), payload bytes; optional chunk_index/total_chunks (uint32)
- Resp: status_code, object_digest (32 bytes SHA‑256), stored_timestamp

GET (3)
- Req: queue_path, selector: latest|by_digest, optional digest (32 bytes)
- Resp: status_code, content_type, payload_len, payload

DELETE (4)
- Req: queue_path, digest
- Resp: status_code

STATUS (5)
- Req: none or minimal
- Resp: node status (uptime, queues, storage usage, protocol version)

SEARCH (6)
- Req: queue_path, filters (time range, prefix, content_type), limit, offset
- Resp: list of object summaries: digest, size, timestamp, content_type, optional name

BYE (7)
- Req/Resp: tear down session; optional reason

9.4 Status Codes (examples)

- 0 OK
- 1 Unauthorized
- 2 Forbidden
- 3 NotFound
- 4 Conflict
- 5 BadRequest
- 6 TooLarge
- 7 RateLimited
- 8 InternalError

9.5 Limits

- Max frame size: implementation‑defined; recommend supporting ≥ 4 MiB per frame, chunking for larger payloads.
- Queue name: ASCII path segments, 1–64 chars per segment, max 256 bytes entire path.

9.6 Frame Examples (Illustrative)

Header layout (common)
- Offset 0: magic 'B' (0x42)
- Offset 1: version (1)
- Offset 2–5: total_length (uint32, big‑endian)
- Offset 6–9: command (uint32)
- Offset 10–25: request_id (UUID, 16 bytes, big-endian byte order)
- Offset 26–41: node_id (UUID of the sender)
- Offset 42–57: user_id (UUID of the user on whose behalf the frame is sent)
- Offset 58…: command-specific payload

HELLO example
- Purpose: establish keys; payload typically cleartext, then both sides derive session keys.
- Payload fields (example): user_uuid (16), node_uuid (16), client_identity_pubkey (32), timestamp (uint64), nonce (24), versions_count (uint8), versions[...] (uint16 each)
- Example header bytes (hex):
  42 01 00 00 00 92 00 00 00 01 00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F 10 11 12 13 14 15 16 17 18 19 1A 1B 1C 1D 1E 1F 20 21 22 23 24 25 26 27 28 29 2A 2B 2C 2D 2E 2F
  Where: magic=42, ver=01, len=0x00000092 (payload 0x5E + 52 bytes d’en-tête), cmd=1 (HELLO), request_id=`00010203-0405-0607-0809-0a0b0c0d0e0f`, node_id=`10111213-1415-1617-1819-1a1b1c1d1e1f`, user_id=`20212223-2425-2627-2829-2a2b2c2d2e2f`.
- Example payload (JSON for clarity):
  {
    "user_uuid": "507FA643-A2A6-47AF-A09E-E235E9727332",
    "node_uuid": "776BA464-BA07-4B6D-B102-11D5D9917C6F",
    "client_identity_pubkey": "ed25519:8c1f...ab42",
    "timestamp": 1736712400123,
    "nonce_hex": "a1b2...",  
    "versions": [1]
  }

PUT example
- Purpose: store an object in a queue; payload is AEAD‑encrypted after HELLO.
- Cleartext logical layout before encryption:
  - queue_path_len (uint16)
  - queue_path (UTF‑8)
  - content_type_len (uint16)
  - content_type (UTF‑8)
  - payload_len (uint32)
  - payload bytes
- Example (queue=/message, content_type=text/plain, payload="hello")
  - queue_path_len = 8, queue_path = "/message"
  - content_type_len = 10, content_type = "text/plain"
  - payload_len = 5, payload = 68 65 6c 6c 6f
- Example header bytes (hex):
  42 01 00 00 00 63 00 00 00 02 AA AA AA AA AA AA AA AA AA AA AA AA AA AA AA BB BB BB BB BB BB BB BB BB BB BB BB BB BB BB CC CC CC CC CC CC CC CC CC CC CC CC CC CC CC CC
  Where: len=0x00000063 (47 bytes logique + 52 d’en-tête), cmd=2 (PUT), `request_id`, `node_id`, `user_id` illustrés ici avec des octets `AA`, `BB`, `CC` pour lisibilité.
  Note: Actual on‑wire payload is AEAD ciphertext with nonce and tag per session parameters.

10. Server (`boxd`) Behavior

- Listen on configurable UDP port; prefer IPv6.
- Register/update presence in embedded LS on start and periodically (keep‑alive with last_seen). Presence is persisted dans la file permanente `whoswho/`.
- Enforce ACLs per queue and per user/node.
- Persist objects sous `~/.box/queues/<queue>/timestamp-UUID.json` (payload base64 + métadonnées incluant `content_type`, `node_id`, `user_id`, `created_at`). **Exception :** la file `whoswho` écrit directement `<uuid>.json` afin que les identifiants de nœud ou d’utilisateur soient mis à jour en place sans proliférer de doublons. Le daemon DOIT provisionner cette hiérarchie au premier démarrage, créer la file `INBOX/` et refuser de démarrer si la création échoue. Les informations LS (`whoswho`, `/location`) sont également stockées via ces files (`whoswho` hébergeant à la fois les enregistrements de nœud et un index utilisateur).
- Chaque queue peut être marquée « permanente » via la configuration (`server.permanent_queues`). Dans ce cas, les opérations `GET` doivent retourner le message sans le supprimer du stockage; les clients sont responsables de la purge explicite (via `DELETE`/`PURGE` à venir) si nécessaire.
- When `port_mapping = true` (ou `--enable-port-mapping`), tenter automatiquement une ouverture : UPnP (`M-SEARCH` IGD → `AddPortMapping` UDP + `GetExternalIPAddress`), PCP (`MAP` UDP/5351 avec nonce, refresh à mi-vie) *et* une requête `PEER` pour percer le pare-feu entrant, puis NAT-PMP (`MAP`/`UNMAP` + `PublicAddress` vers la passerelle par défaut). Chaque étape doit être journalisée, retirée proprement (`DeletePortMapping` / lifetime 0) à l’arrêt, et expose un code d’erreur structuré. En cas de succès, la coordination lance une sonde reachability légère (HELLO UDP à l’adresse externe découverte) afin de vérifier que l’endpoint annoncé fonctionne réellement. Les réponses admin exposent `port_mapping_status`, `port_mapping_error`, `port_mapping_error_code`, `port_mapping_backend`, `port_mapping_external_port`, `port_mapping_external_ipv4`, `port_mapping_lease_seconds`, `port_mapping_refreshed_at`, `port_mapping_peer_status`, `port_mapping_peer_lifetime`, `port_mapping_peer_last_updated`, `port_mapping_peer_error`, `port_mapping_reachability_status`, `port_mapping_reachability_round_trip_millis`, `port_mapping_reachability_checked_at` et `port_mapping_reachability_error` pour suivre l’état courant. Les opérateurs peuvent fournir un fallback manuel (`external_address`, `external_port` dans `Box.plist` ou `--external-address/--external-port`) : l’admin channel restitue alors `manualExternalAddress|Port|Origin` et les enregistrements Location Service ajoutent des entrées `addresses[]` avec `source = manual` (CLI) ou `source = config` (PLIST).
- Optional at‑rest encryption with a server‑managed key.
- Rate limiting and DoS protection per source.

11. Configuration

11.1 Process/User Requirements

- `boxd` must not run as `root` on Unix or as an Administrator on Windows. It must run under a real, non‑privileged user account.
- The daemon should refuse to start if it detects elevated privileges (effective UID 0 on Unix; elevated token on Windows).

11.2 File Locations

- Unix/macOS:
  - Config: `~/.box/Box.plist`
  - Queues root: `~/.box/queues/` (permissions `700`)
- Keys: `~/.box/keys/node.identity.json` (serveur), `~/.box/keys/client.identity.json` (optionnel) — format JSON (hex) généré par `BoxNoiseKeyStore` en attendant l’intégration libsodium.
- Windows:
  - Config: `%USERPROFILE%\.box\Box.plist`
  - Queues root: `%USERPROFILE%\.box\queues`
- Keys: `%USERPROFILE%\\.box\keys\node.identity.json`

11.3 Formats

- Configuration: Property List (PLIST) XML avec trois sections obligatoires:
  - `common`: `node_uuid` (UUID), `user_uuid` (UUID). Générés au premier lancement; réutilisés par client et serveur.
  - `server`: `port` (UInt16), `log_level` (`trace|debug|info|warn|error|critical`), `log_target` (`stderr|stdout|file:<path>` — par défaut `file:~/.box/logs/boxd.log`), paramètres de transport (`transport`, `transport_status`, `transport_put`, `transport_get`), `admin_channel` (booléen), options Noise (`pre_share_key`, `noise_pattern`).
  - `client`: `address` (IPv4/IPv6 ou nom), `port` (UInt16), `log_level`, `log_target` (par défaut `file:~/.box/logs/box.log`).
- Données internes: fichiers JSON par message dans `~/.box/queues/<queue>/` (cf. section 10), encodés en UTF‑8/base64.

11.4 Exemple minimal `~/.box/Box.plist`

```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>common</key>
  <dict>
    <key>node_uuid</key><string>F0E0D0C0-B0A0-9080-7060-504030201000</string>
    <key>user_uuid</key><string>00010203-0405-0607-0809-0A0B0C0D0E0F</string>
  </dict>
  <key>server</key>
  <dict>
    <key>port</key><integer>12567</integer>
    <key>log_level</key><string>info</string>
    <key>log_target</key><string>file:/Users/you/.box/logs/boxd.log</string>
    <key>admin_channel</key><true/>
    <key>transport</key><string>clear</string>
    <key>port_mapping</key><false/>
  </dict>
  <key>client</key>
  <dict>
    <key>address</key><string>127.0.0.1</string>
    <key>port</key><integer>12567</integer>
    <key>log_level</key><string>info</string>
    <key>log_target</key><string>file:/Users/you/.box/logs/box.log</string>
  </dict>
</dict>
</plist>
```

Legacy TOML configurations (client/daemon ACLs) restent valables pour l’implémentation C et servent de référence tant que l’équivalent PLIST n’est pas finalisé. Les sections suivantes décrivent le schéma historique (à porter vers PLIST ou une représentation dédiée lors de la migration ACL).

11.5 ACL Configuration

Evaluation rules:
- Principals: matched by `user_uuid`, `node_uuid`, or the special `owner` principal (the daemon’s own user/node UUIDs) and `any` (all authenticated peers).
- Global × Queue: compute allowed capabilities as the intersection of global allows and queue allows for a given principal and queue path. Denies at either level subtract capabilities. Default is deny.
- Capabilities: one or more of `put`, `get`, `list`, `delete`.

Schema outline (TOML):
- Global entries may optionally scope to specific queues via `queues = ["/queue", "*"]`.
- Queue entries are defined under `acl.queue."<queue-path>"`.

Example defaults emphasizing privacy with explicit grants for standard queues:

  [acl.global]
  default = "deny"

  # Owner (this node’s user/node) has full capabilities everywhere
  [[acl.global.allow]]
  principal = { type = "owner" }
  capabilities = ["put", "get", "list", "delete"]
  queues = ["*"]

  # Allow everyone to read presence and location (can be tightened as needed)
  [[acl.global.allow]]
  principal = { type = "any" }
  capabilities = ["get", "list"]
  queues = ["/whoswho", "/location"]

  # Example: deny delete for everyone on public queues at global level
  [[acl.global.deny]]
  principal = { type = "any" }
  capabilities = ["delete"]
  queues = ["/whoswho", "/location"]

  # Queue-level: /whoswho — owner publishes presence; anyone may read
  [acl.queue."/whoswho"]

  [[acl.queue."/whoswho".allow]]
  principal = { type = "owner" }
  capabilities = ["put", "delete"]

  [[acl.queue."/whoswho".allow]]
  principal = { type = "any" }
  capabilities = ["get", "list"]

  # Queue-level: /location — owner publishes location; anyone may read
  [acl.queue."/location"]

  [[acl.queue."/location".allow]]
  principal = { type = "owner" }
  capabilities = ["put", "delete"]

  [[acl.queue."/location".allow]]
  principal = { type = "any" }
  capabilities = ["get", "list"]

  # Queue-level: /message — only selected peers may send; owner reads and manages
  [acl.queue."/message"]

  # Trusted peer allowed to send messages
  [[acl.queue."/message".allow]]
  principal = { type = "user", id = "9B6DF823-6E22-4BAD-BB6E-77EC6F71AEF1" }
  capabilities = ["put"]

  # Owner can read, list, and delete from /message
  [[acl.queue."/message".allow]]
  principal = { type = "owner" }
  capabilities = ["get", "list", "delete"]

Notes:
- Replace the example trusted user UUIDs with actual peers.
- To fully block a specific peer, add a matching `deny` entry at global or queue level with all capabilities for that principal.

11.6 ACL Evaluation Examples

Example 1 — Read presence from whoswho (allowed):
- Global: `any` allowed `get`, `list` on `/whoswho`.
- Queue `/whoswho`: `any` allowed `get`, `list`.
- Result: `any` principal may `get`/`list` objects from `/whoswho`.

Example 2 — Untrusted user sending to /message (denied):
- Global: default deny.
- Queue `/message`: only specific `user` UUIDs have `put`.
- Principal: `user` UUID not listed.
- Result: No allow rule applies ⇒ denied.

Example 3 — Deny overrides allow:
- Global: `any` allowed `get`, `list` on `/location`; also `any` denied `delete` on `/location`.
- Queue `/location`: `owner` allowed `put`, `delete`; `any` allowed `get`, `list`.
- Principal: `any` attempting `delete`.
- Result: Intersected capabilities remove `delete` due to global deny ⇒ denied.

Example 4 — Specific node override:
- Global: `any` allowed `put` on `/message` (temporary open inbox).
- Queue `/message`: deny `node` id `BAD-UUID...` for `put`.
- Principal: that specific node.
- Result: Queue‑level deny subtracts `put` ⇒ denied for that node; other peers remain allowed.

11.7 NAT‑Related Configuration

In `~/.box/boxd.toml`:

  [network]
  listen = "[::]:9988"
  prefer_ipv6 = true

  [network.nat]
  enable_port_mapping = false        # user must opt‑in
  methods = ["pcp", "natpmp", "upnp"]
  keepalive_secs = 25

  [network.hole_punch]
  enable = false
  rendezvous_peers = []              # optional list of user‑owned reachable peers for coordination

  [network.relay]
  enable = false
  endpoints = []                     # optional user‑owned relays (IPv6 preferred)

12. Observability

- Structured logs with levels; redaction of sensitive data.
- Health endpoints via STATUS; local admin CLI for queue inspection.

13. Versioning and Compatibility

- Protocol `version` in frame header; peers advertise supported versions in HELLO.
- Backward compatibility within a major version; avoid breaking changes without a version bump.

14. Dependencies

- Crypto: a well‑vetted library for Ed25519/X25519 and XChaCha20‑Poly1305 (e.g., libsodium, or platform equivalents).
- Storage: local filesystem plus a binary B‑tree index. Pluggable backends may use BSD `libdb`, LMDB, or an equivalent portable store.
 - OS: Linux/macOS; IPv6 preferred, IPv4 supported.

14.1 Storage layers (implementation roadmap)

- `BFFileManager` — abstraction minimale des I/O fichier/
  - Crée/Supprime fichiers et répertoires depuis une racine déterminée.
  - Lit/écrit des contenus via `BFData` (lecture binaire, écriture atomique temporaire + rename).
  - Expose des helpers pour lister un dossier, vérifier l’existence, obtenir tampons `BFData`, tout en encapsulant les détails POSIX/Windows.

- `BFStorageManager` — logique métier Box au-dessus de `BFFileManager`.
  - Organise la hiérarchie `{storage_root}/queues/<queue>/` (par défaut `~/.box/queues` dans la réécriture Swift ; configurable via la section `server` de `Box.plist`).
  - API envisagée :
    - `Put(queue, data, metadata)` → écrit un fichier (ex. `<timestamp>-<digest>.msg`) et retourne un `messageId` explicite.
    - `GetLast(queue)` → rend la dernière entrée (ordre par horodatage/id).
    - `GetById(queue, messageId)` → lecture ciblée.
    - Extensions futures : `Delete`, `List`, index B-tree pour recherche.
  - Raccroche les index (B-tree) dans une version ultérieure (prévoir un emplacement type `{queue}/index.db`).
  - Stratégie concurrente : décider si `BFStorageManager` sérialise en interne (mutex) ou si `boxd` séquence les appels.

- Tests :
  - `test_BFFileManager` → création/suppression/nested directories, lecture d’un fichier, comportement erreur.
  - `test_BFStorageManager` → `Put`/`Get`, génération d’id, lecture d’un `queueKey` inexistant, intégration basique.

- À long terme : abstraction plugable pour changer de backend (LMDB) sans impacter `BFStorageManager`.

15. Open Questions / TBD

- NAT traversal/STUN/ICE: out of scope for MVP; evaluate later.
- LS trust model: single user self‑hosted vs. federated/trusted peers; define revocation semantics.
- Object retention policies and quotas.
- Multi‑factor or additional client attestation options.

16. NAT Traversal

16.1 Context

- IPv6: No NAT, but home gateways (CPE) typically block unsolicited inbound by default. Add an allow rule for the Box UDP port.
- IPv4: NAT prevents unsolicited inbound. Some ISPs place customers behind CGNAT, making manual port forwarding impossible.
- France ISP reality (typical, subject to model/firmware):
  - Orange Livebox: IPv6 on by default; inbound IPv6 blocked unless opened. UPnP IGD present; PCP varies.
  - Free Freebox: Native IPv6; NAT‑PMP and UPnP; PCP on newer Freebox OS; port rules straightforward.
  - SFR/Bouygues: IPv6 increasingly available; UPnP/port forwarding common; some offers use IPv4 CGNAT.

16.2 Strategy (preference order)

- Prefer IPv6: run `boxd` on a global IPv6 address; open a firewall rule for UDP `<port>`; share `[ipv6]:<port>` as bootstrap.
- Automatic mapping (opt‑in): attempt PCP → NAT‑PMP → UPnP against the default gateway only.
- Manual configuration: if auto‑mapping fails, guide user to add IPv4 UDP port forward and an IPv6 firewall allow rule.
- UDP hole punching: optional; use a rendezvous peer to create state; variable success depending on NAT type.
- User‑owned relay: optional last resort; e2e encrypted so relay is blind; user controls the infrastructure.

16.3 Methods

- PCP: Can request IPv4 mappings and IPv6 pinholes with lifetimes; renew periodically before expiry.
- NAT‑PMP: Common on Freebox; request external port and TTL; renew on schedule.
- UPnP IGD: Widely available; use only on the local gateway; never accept WAN advertisements.

16.4 Keepalives and Probing

- Maintain UDP state with keepalives every 20–30 seconds (configurable `keepalive_secs`).
- Perform low‑rate path probes to detect external address changes; update Location Service records on change.

16.5 Connectivity Check Flow

- Step 1: Local assessment — detect IPv6 global address, gateway capabilities (PCP/NAT‑PMP/UPnP), NAT type (best‑effort).
- Step 2: Inbound IPv6 test — ask a cooperating peer to send a HELLO to your `[ipv6]:port`; verify receipt.
- Step 3: Port mapping (if enabled) — acquire a mapping; publish the discovered external IPv4 endpoint to peers via LS.
- Step 4: Hole punch test (optional) — coordinate via rendezvous; attempt mutual UDP flows.
- Step 5: Relay fallback (optional) — verify latency and throughput to configured user‑owned relay.

16.6 Security and Privacy

- Require explicit user consent to enable port mapping and hole punching.
- Limit discovery and control traffic to the local default gateway; do not broadcast beyond local link.
- Log discovered external endpoints and mapping lifetimes; never log payloads or keys.
- Enforce ACLs identically regardless of path (direct, punched, or relayed).

17. Connectivity Check CLI

- Command: `box check connectivity [options]`
- Purpose: Diagnose and report reachability for `boxd` over IPv6 and IPv4, attempt optional port mappings, and verify hole punching/relay paths.

Options
- `--enable-port-mapping`: Temporarily attempt PCP/NAT‑PMP/UPnP per configured `methods` (does not persist config).
- `--methods <list>`: Comma‑separated subset of `pcp,natpmp,upnp` to try in order.
- `--peer <addr>`: Optional cooperating peer address for inbound tests and hole punching, e.g., `box://<user_uuid>@[ipv6]:port` or `<ip>:<port>`.
- `--json`: Machine‑readable output.

Behavior
- IPv6 assessment: detect global IPv6, test inbound by asking the peer (or a loopback helper if local admin channel is available) to send a HELLO to `[ipv6]:port`.
- IPv4 mapping: if enabled, acquire a UDP mapping, report external `<ip>:<port>` and lifetime; publish to LS only if user confirms.
- Hole punching: if a peer is supplied, coordinate a mutual UDP attempt and report success/failure.
- Relay: if a user‑owned relay is configured and enabled, test reachability and latency.

Output (human)
- Summary lines with statuses, for example:
  - IPv6: reachable on `[2001:db8::10]:9988` (inbound OK)
  - IPv4: mapped to `203.0.113.20:45012` via PCP (lifetime 1800s)
  - Hole punching with 507F…7332@[2001:db8::20]:9988: success (RTT 42 ms)
  - Relay `[2001:db8::100]:4444`: reachable (RTT 85 ms)
  - Recommendation: prefer IPv6; keepalive 25s; save mapping to config? [y/N]

Output (JSON when `--json`)
- Fields: `ipv6 {reachable, address, port}`, `ipv4 {mapped, external, lifetime, method}`, `hole_punch {peer, success, rtt_ms}`, `relay {reachable, rtt_ms}`, `advice []`.

Safety
- Never enables persistent mappings without explicit user confirmation or config changes.
- Limits discovery traffic to the default gateway; no WAN UPnP.

17.1 Local Admin Channel

- Purpose: Secure, local-only control plane for `box` to query/drive the co-resident `boxd` during diagnostics and administration.

- Transport
  - Unix/macOS: Unix domain socket at `~/.box/run/boxd.socket` (directory mode 700; socket mode 600).
  - Windows: Named pipe `\\.\pipe\boxd-admin` with an ACL restricting access to the owning user.

- Authentication/Authorization
  - Access is restricted by OS-level file/pipe permissions to the same non-privileged user that owns `boxd`.
  - `boxd` refuses admin-channel requests if the caller is not the same user.
  - Swift rewrite (MVP 2025): admin commands are invoked as plain text lines (`status`, `ping`, `log-target <target|json>`, `reload-config [json]`, `stats`, `nat-probe [json]`, `locate <uuid>`, `location-summary [flags]`) retournant un JSON terminé par un saut de ligne. `locate` accepte un UUID de nœud (réponse `{"record": …}`) ou un UUID d’utilisateur (réponse `{"user": {"nodeUUIDs": [...], "records": [...]}}`). `location-summary` renvoie un instantané supervisant les entrées `whoswho/` (totaux, seuil, identifiants stale) et peut être consommé via le CLI pour enclencher des alertes. Dans tous les cas, la commande refuse de divulguer des informations si le couple `(node_id, user_id)` du demandeur n’a jamais été enregistré.
  - Implementation status (2025-10): socket Unix et named pipe Windows disponibles avec ACL restreintes; `log-target` pilote Puppy (`stderr|stdout|file:`) et `reload-config` relit les PLIST. Restent à intégrer: tests d’intégration CLI↔️serveur et les commandes NAT/LS décrites ci-dessous.

- Message Format
  - Framing: newline-delimited JSON (NDJSON) or CBOR frames; implementation MAY choose CBOR for efficiency.
  - Request: `{ "id": "uuid", "action": "status|nat_probe|map_create|map_delete|probe_peer|ls_publish", "params": { ... } }`
  - Response: `{ "id": "uuid", "ok": true|false, "result": { ... } | "error": { "code": "...", "msg": "..." } }`

- Actions (initial)
  - `status`: returns node/user UUIDs (`node_uuid` now persisté), listen addrs, protocol versions, filesystem metrics (free bytes available under `~/.box/queues/`), and queue statistics (`queueCount` où `INBOX` garantit un minimum de 1).
  - `nat_probe`: inspects gateway capabilities (PCP/NAT-PMP/UPnP) and returns supported methods.
  - `map_create { method, port, ttl }`: attempts to create a UDP mapping/pinhole; returns external endpoint and lifetime.
  - `map_delete { method, external }`: removes a previously created mapping.
  - `probe_peer { address, port }`: initiates an outbound probe/HELLO to a cooperating peer and returns reachability/RTT.
  - `ls_publish { endpoints }`: publishes updated external endpoints to the embedded LS (requires confirmation by CLI).

- Notes
  - Inbound verification requires a cooperating external peer or a user-owned relay; the admin channel cannot simulate Internet-origin traffic.
- The admin channel is optional; `box` falls back to best‑effort local checks if unavailable.

18. Threat Model (Summary)

Assets
- Data in transit between nodes (messages/files, metadata).
- Identity keys (Ed25519), session keys, ACL configurations.
- Presence/location data in `whoswho` and `/location`.

Adversaries and Capabilities
- Passive network observer: can capture packets but cannot break modern crypto.
- Active network attacker: can inject, replay, reorder, or drop UDP packets; can run their own nodes.
- Compromised peer: presents valid UUIDs/keys but behaves maliciously within its authorization.
- Local attacker on host: attempts to access files or admin channel without proper privileges.

Threats and Mitigations
- Eavesdropping on payloads → AEAD (XChaCha20‑Poly1305) with Noise NK/IK; payloads encrypted and authenticated.
- Impersonation/MITM → verify server identity key via LS and/or bootstrap fingerprint; signed transcripts; replay protection.
- Replay attacks → nonces + monotonic timestamps; per‑peer replay cache; reject stale/duplicate nonces.
- Unauthorized access → default‑deny ACLs; admission control requiring LS registration; per‑queue capabilities.
- Downgrade or version confusion → HELLO advertises and negotiates versions; reject unknown/unsupported versions.
- DoS via floods → rate limiting, per‑source quotas, bounded buffers; optional port‑knock or proof‑of‑work in future.
- Data tampering at rest → content digests (SHA‑256) and optional at‑rest encryption; integrity checks on read.
- Local privilege escalation → `boxd` refuses to run as root/admin; key/dir permissions enforced; admin channel same‑user only.

Out of Scope (Current)
- STUN/ICE/TURN; third‑party relay services not under user control.
- Protecting against a fully compromised host OS.
- Metadata privacy across traffic analysis beyond timing/size obfuscation.

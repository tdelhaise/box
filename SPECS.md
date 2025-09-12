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
- Replay protection is enforced using nonces and monotonic timestamps; servers reject stale or duplicate nonces per peer.

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
  - Prefer IPv6 with globally routable addresses. If using IPv4, configure port forwarding on the gateway for the UDP port used by `boxd`.
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
        "ip": "2001:db8::10",
        "port": 9988,
        "node_public_key": "ed25519:8c1f...ab42",
        "online": true,
        "since": 1736712345123,
        "last_seen": 1736712389456
      }
    ]
  }

Resolve by Node UUID
- Request
  { "op": "resolve", "node_uuid": "776BA464-BA07-4B6D-B102-11D5D9917C6F" }
- Response
  { "ok": true, "node": { /* same shape as in nodes[] above */ } }

6.7 Location Service CBOR CDDL (Informative)

- The following CDDL sketches the CBOR encoding for LS messages. Field names mirror the JSON forms above.

  ; Primitives
  uuid = b16 .size 16         ; 16-byte UUID (binary)
  tstr-nonempty = tstr .regexp ".+" ; non-empty text
  port = 0..65535

  ; Node record as used by LS
  node-record = {
    "user_uuid": uuid,
    "node_uuid": uuid,
    "ip": tstr-nonempty,             ; textual IP (IPv6/IPv4)
    "port": port,
    "node_public_key": tstr-nonempty, ; e.g., "ed25519:" + hex
    "online": bool,
    "since": uint,
    "last_seen": uint,
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

6.8 Location Service CBOR Examples (Hex + Diagnostic)

Notes
- These examples illustrate one possible canonical CBOR encoding. Implementations do not need to match byte-for-byte as long as they produce valid messages conforming to the schema. Byte strings for UUIDs are 16 bytes; values below are sample data.

Example A — ls-register (minimal, without tags)

Diagnostic notation
  {
    "op": "register",
    "record": {
      "user_uuid": h'000102030405060708090A0B0C0D0E0F',
      "node_uuid": h'F0E0D0C0B0A090807060504030201000',
      "ip": "2001:db8::10",
      "port": 9988,
      "node_public_key": "ed25519:00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
      "online": true,
      "since": 1,
      "last_seen": 2
    }
  }

Exact hex (canonical CBOR, sorted map keys)
  a2626f70687265676973746572667265636f7264a86269706c323030313a6462383a3a313064706f72741927046573696e636501666f6e6c696e65f5696c6173745f7365656e02696e6f64655f7575696450f0e0d0c0b0a09080706050403020100069757365725f7575696450000102030405060708090a0b0c0d0e0f6f6e6f64655f7075626c69635f6b65797848656432353531393a30303131323233333434353536363737383839394141424243434444454546463030313132323333343435353636373738383939414142424343444445454646

Field note: Replace the example port 9972 (0x26F4) with 9988 (0x2704) in your encoder.

Example B — ls-resolve-user response (single node)

Diagnostic notation
  {
    "ok": true,
    "nodes": [
      {
        "user_uuid": h'000102030405060708090A0B0C0D0E0F',
        "node_uuid": h'F0E0D0C0B0A090807060504030201000',
        "ip": "2001:db8::10",
        "port": 9988,
        "node_public_key": "ed25519:00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF",
        "online": true,
        "since": 1,
        "last_seen": 2
      }
    ]
  }

Exact hex (canonical CBOR, sorted map keys)
  a2626f6bf5656e6f64657381a86269706c323030313a6462383a3a313064706f72741927046573696e636501666f6e6c696e65f5696c6173745f7365656e02696e6f64655f7575696450f0e0d0c0b0a09080706050403020100069757365725f7575696450000102030405060708090a0b0c0d0e0f6f6e6f64655f7075626c69635f6b65797848656432353531393a30303131323233333434353536363737383839394141424243434444454546463030313132323333343435353636373738383939414142424343444445454646

Ellipses (...) indicate trimmed string bodies for brevity; actual encodings include the full text contents.

7. Data Model

- Queue: A namespace under a user’s server for storing objects. Example queues: `/message`, `/photos`, `/ids`.
- Object: Arbitrary binary blob with metadata: content_type, size, timestamp, digest (SHA‑256), optional filename.
- Addressing: `<user_uuid>[@<node_uuid>]/<queue>` uniquely identifies a destination. If `@<node_uuid>` is omitted, the client picks a suitable node from LS.

7.1 Access Control Lists (ACLs)

- Every queue has an attached ACL. Effective permissions are the conjunction of global ACL and queue‑level ACL (both must allow).
- ACL entries may target User UUIDs and/or Node UUIDs with capabilities: put/get/delete/list.
- Default policy is deny‑by‑default unless explicitly allowed.

7.2 Standard Queues

- `/uuid` (content_type: `application/cbor` or `application/json`):
  - Purpose: Publish presence and status per User UUID and Node UUID. Used internally by the embedded Location Service.
  - Object schema (logical):
    - user_uuid (UUID), node_uuid (UUID)
    - status (enum: "online" | "offline")
    - since (timestamp), last_seen (timestamp)
    - node_public_key (bytes), protocol_versions ([uint16])
  - ACL: readable by authorized peers; writable by the owning user’s nodes; delete restricted to owner/admin.
  - JSON example:
    {
      "user_uuid": "507FA643-A2A6-47AF-A09E-E235E9727332",
      "node_uuid": "776BA464-BA07-4B6D-B102-11D5D9917C6F",
      "status": "online",
      "since": 1736712345123,
      "last_seen": 1736712389456,
      "node_public_key": "ed25519:8c1f...ab42",
      "protocol_versions": [1]
    }
  - CBOR CDDL sketch (informative):
    uuid = b16 .size 16 ; 16‑byte UUID
    presence = {
      "user_uuid": uuid,
      "node_uuid": uuid,
      "status": "online" / "offline",
      "since": uint,
      "last_seen": uint,
      "node_public_key": tstr,   ; "ed25519:" + hex
      "protocol_versions": [* uint]
    }

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
- 8 bytes: request_id (uint64) to correlate replies
- Remaining: command‑specific payload (usually encrypted AEAD after an initial handshake)

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
- Offset 10–17: request_id (uint64)
- Offset 18…: command‑specific payload

HELLO example
- Purpose: establish keys; payload typically cleartext, then both sides derive session keys.
- Payload fields (example): user_uuid (16), node_uuid (16), client_identity_pubkey (32), timestamp (uint64), nonce (24), versions_count (uint8), versions[...] (uint16 each)
- Example header bytes (hex):
  42 01 00 00 00 5E 00 00 00 01 00 00 00 00 00 00 00 01
  Where: magic=42, ver=01, len=0x0000005E (94 bytes payload), cmd=1 (HELLO), req_id=1.
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
  42 01 00 00 00 2F 00 00 00 02 00 00 00 00 00 00 00 02
  Where: magic=42, ver=01, len=0x0000002F (47 bytes logical payload), cmd=2 (PUT), req_id=2.
  Note: Actual on‑wire payload is AEAD ciphertext with nonce and tag per session parameters.

10. Server (`boxd`) Behavior

- Listen on configurable UDP port; prefer IPv6.
- Register/update presence in embedded LS on start and periodically (keep‑alive with last_seen). Presence is also published into `/uuid`.
- Enforce ACLs per queue and per user/node.
- Persist objects under a storage root: default filesystem layout: `<root>/<user_uuid>/<queue>/<digest>` with metadata sidecar. LS data is also persisted via `/uuid` and `/location` queues.
- Optional at‑rest encryption with a server‑managed key.
- Rate limiting and DoS protection per source.

11. Configuration

11.1 Process/User Requirements

- `boxd` must not run as `root` on Unix or as an Administrator on Windows. It must run under a real, non‑privileged user account.
- The daemon should refuse to start if it detects elevated privileges (effective UID 0 on Unix; elevated token on Windows).

11.2 File Locations

- Unix/macOS:
  - Config: `~/.box/box.toml` (CLI) and `~/.box/boxd.toml` (daemon)
  - Data root: `~/.box/data`
  - Keys: `~/.box/keys/identity.ed25519` (server), `~/.box/keys/client.ed25519` (optional)
  - Permissions: directories `700`, key files `600`.
- Windows:
  - Config: `%USERPROFILE%\.box\box.toml` and `%USERPROFILE%\.box\boxd.toml`
  - Data root: `%USERPROFILE%\.box\data`
  - Keys: `%USERPROFILE%\.box\keys\identity.ed25519`

11.3 Formats

- Configuration: human‑readable TOML.
- Internal data: binary format. Default implementation uses filesystem objects with a portable B‑tree index.
  - Implementation options (pluggable): BSD `libdb` (available on macOS/FreeBSD/OpenBSD), LMDB, or a compact custom B‑tree. Choice is an implementation detail; on platforms where `libdb` is unavailable, use a portable alternative.

11.4 Bootstrap Configuration Snippets

Example `~/.box/box.toml` (client):

  [identity]
  user_uuid = "9B6DF823-6E22-4BAD-BB6E-77EC6F71AEF1"
  key_path  = "~/.box/keys/client.ed25519"

  [network]
  prefer_ipv6 = true
  timeout_ms  = 8000

  [bootstrap."507FA643-A2A6-47AF-A09E-E235E9727332"]
  endpoints   = ["[2001:db8::10]:9988", "203.0.113.20:9988"]
  fingerprint = "ed25519:8c1f...ab42"

Example `~/.box/boxd.toml` (daemon):

  [identity]
  user_uuid = "507FA643-A2A6-47AF-A09E-E235E9727332"
  node_uuid = "776BA464-BA07-4B6D-B102-11D5D9917C6F"
  key_path  = "~/.box/keys/identity.ed25519"

  [network]
  listen      = "[::]:9988"  # or "0.0.0.0:9988"
  prefer_ipv6 = true

  [storage]
  data_root = "~/.box/data"
  backend   = "portable-btree"  # or "bsd-db" | "lmdb" (implementation‑dependent)

  # Optional: bootstrap peers the daemon may contact when originating client actions
  [bootstrap]
  # Map of user_uuid => endpoints and optional fingerprint
  [bootstrap."9B6DF823-6E22-4BAD-BB6E-77EC6F71AEF1"]
  endpoints   = ["[2001:db8::20]:9988"]
  fingerprint = "ed25519:aa12...44ef"

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
  queues = ["/uuid", "/location"]

  # Example: deny delete for everyone on public queues at global level
  [[acl.global.deny]]
  principal = { type = "any" }
  capabilities = ["delete"]
  queues = ["/uuid", "/location"]

  # Queue-level: /uuid — owner publishes presence; anyone may read
  [acl.queue."/uuid"]

  [[acl.queue."/uuid".allow]]
  principal = { type = "owner" }
  capabilities = ["put", "delete"]

  [[acl.queue."/uuid".allow]]
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

Example 1 — Read presence from /uuid (allowed):
- Global: `any` allowed `get`, `list` on `/uuid`.
- Queue `/uuid`: `any` allowed `get`, `list`.
- Result: `any` principal may `get`/`list` objects from `/uuid`.

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
  - Unix/macOS: Unix domain socket at `~/.box/run/boxd.sock` (directory mode 700; socket mode 600).
  - Windows: Named pipe `\\.\pipe\boxd` with an ACL restricting access to the owning user.

- Authentication/Authorization
  - Access is restricted by OS-level file/pipe permissions to the same non-privileged user that owns `boxd`.
  - `boxd` refuses admin-channel requests if the caller is not the same user.

- Message Format
  - Framing: newline-delimited JSON (NDJSON) or CBOR frames; implementation MAY choose CBOR for efficiency.
  - Request: `{ "id": "uuid", "action": "status|nat_probe|map_create|map_delete|probe_peer|ls_publish", "params": { ... } }`
  - Response: `{ "id": "uuid", "ok": true|false, "result": { ... } | "error": { "code": "...", "msg": "..." } }`

- Actions (initial)
  - `status`: returns node/user UUIDs, listen addrs, protocol versions, and current external endpoints (if known).
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
- Presence/location data in `/uuid` and `/location`.

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

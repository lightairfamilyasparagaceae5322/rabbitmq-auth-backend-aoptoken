# rabbitmq-auth-backend-aoptoken

An authentication backend for RabbitMQ that lets clients authenticate with a
**pre-issued JWT token** (an opaque `token:<jwt>` string placed in the
AMQP password field), **side by side** with normal username/password users —
on the **same account**, with **no client changes**.

It is aimed at environments migrating from Pulsar/AoP-based brokers (which
issue minimal `{"sub":"<user>"}` JWTs used as passwords) to native RabbitMQ,
where the built-in `rabbitmq_auth_backend_oauth2` rejects such minimal tokens
and the internal backend can only store one secret per user.

## How it works

RabbitMQ natively supports an **authentication backend chain**. Configure
internal first (username/password), then this backend for tokens, delegating
authorization back to internal:

```ini
# rabbitmq.conf
auth_backends.1 = internal
auth_backends.2.authn = rabbit_auth_backend_aoptoken
auth_backends.2.authz = internal
```

On each login RabbitMQ tries the backends in order — the client never declares
a mode:

1. `internal` hashes the presented secret and compares it to the stored
   password. Match → password auth.
2. Otherwise this backend sees the `token:` prefix, verifies the JWT's
   signature with a configured key (the algorithm comes from the token's own
   header), and takes the `sub` claim as the identity.
3. Authorization uses `internal` (the vhost permissions already defined for
   that identity).

## Configuration

Configure a symmetric secret, a public key, or both — the plugin picks one
based on the algorithm declared by each token.

Settings go in `rabbitmq.conf`, alongside the auth chain itself:

```ini
## symmetric secret for HS256/HS384/HS512 — one of:
auth_aoptoken.key_file = /etc/rabbitmq/token.key
# auth_aoptoken.key_base64 = Jw...
# auth_aoptoken.key = ...

## public key for RS*/ES* (PEM, or DER SubjectPublicKeyInfo) — one of:
# auth_aoptoken.public_key_file = /etc/rabbitmq/token-public.pem
# auth_aoptoken.public_key_base64 = LS0t...
# auth_aoptoken.public_key = -----BEGIN PUBLIC KEY-----...

## optional
# auth_aoptoken.audience = my-cluster   ## require a matching "aud" claim
# auth_aoptoken.leeway_seconds = 0      ## clock skew allowance for exp/nbf
# auth_aoptoken.accept_bare_jwt = false ## also accept a JWT sent without the token: prefix
```

Prefer the `*_file` forms for secrets: `rabbitmq.conf` tends to end up in
configuration management and backups, whereas a key file can be
permission-bound.

<details>
<summary><code>advanced.config</code> instead</summary>

The same settings live under the `rabbitmq_auth_backend_aoptoken` application,
should you prefer Erlang terms or need to template the file:

```erlang
[
  {rabbitmq_auth_backend_aoptoken, [
     {key_file,          "/etc/rabbitmq/token.key"},
     %% {key_base64,     "Jw..."},
     %% {key,            <<"...">>},
     %% {public_key_file,   "/etc/rabbitmq/token-public.pem"},
     %% {public_key_base64, "LS0t..."},
     %% {public_key,        <<"-----BEGIN PUBLIC KEY-----...">>},
     %% {audience,       <<"my-cluster">>},
     %% {leeway_seconds, 0},
     %% {accept_bare_jwt, false}
  ]}
].
```

Both files are read; `advanced.config` wins where they overlap. Note that
`advanced.config` is only picked up from the standard configuration directory
(`/etc/rabbitmq` for the Debian and RPM packages,
`$RABBITMQ_HOME/etc/rabbitmq` for the generic UNIX build). Point
`RABBITMQ_ADVANCED_CONFIG_FILE` elsewhere and the filename must include the
`.config` suffix, or the file is silently ignored.
</details>

### Settings

| setting | default | when not configured |
|---|---|---|
| `key` / `key_base64` / `key_file` | *(none)* | `HS*` tokens are refused and a warning is logged |
| `public_key` / `public_key_base64` / `public_key_file` | *(none)* | `RS*` / `ES*` tokens are refused and a warning is logged |
| `audience` | *(none)* | the `aud` claim is not checked |
| `leeway_seconds` | `0` | `exp` / `nbf` are compared against the clock with no tolerance |
| `accept_bare_jwt` | `false` | only credentials starting with `token:` are treated as tokens |

Within each key group the first configured form wins, in the order listed
above. Nothing has a built-in key: the plugin never ships with one, and never
falls back to a default secret or path.

**If no key at all is configured the plugin simply refuses every token** — it
does not interfere with the rest of the chain, so `internal` username/password
authentication keeps working normally. Keys are read once and cached; changing
a config value reloads them.

## Logging

Every decision this backend makes is reported at debug level, so an auth chain
can be traced without a packet capture:

```ini
# rabbitmq.conf
log.file.level = debug
```

```
rabbitmq_auth_backend_aoptoken: 'app1' presented a bearer token (84 bytes)
rabbitmq_auth_backend_aoptoken: accepted a HS256 token presented as 'app1'; authenticating as its subject 'app1'
rabbitmq_auth_backend_aoptoken: refused a HS256 token presented as 'app1': token has expired
rabbitmq_auth_backend_aoptoken: 'app1' presented a password rather than a bearer token, leaving it to the rest of the chain
```

The line naming both the login the client connected as and the subject it was
authenticated as is usually the one you want: those differ whenever a client's
configured username does not match the identity inside its token.

**Tokens and keys are never written to the log, at any level** — a presented
token is reported only by its size. The algorithm is read from the token header
before any signature has been checked, so it is treated as untrusted: it is
truncated and stripped to identifier characters before being logged or returned
to the client, and cannot flood the log or forge a line break in it.

Each key is reported once at info level when it is first loaded, and again
whenever the configuration changes:

```
rabbitmq_auth_backend_aoptoken: loaded symmetric key from /etc/rabbitmq/token.key (32 bytes, sha256:225c9ff2)
```

The fingerprint is the first four bytes of the key's SHA-256. It identifies the
key without disclosing it, so it can be compared against `sha256sum` of the
intended file, or across the nodes of a cluster, to confirm the running node
picked up the key you meant. An inline key is named rather than printed.

A missing or unreadable key is reported once per authentication at warning
level, and is the one case worth alerting on.

## Troubleshooting

| symptom | what it means |
|---|---|
| A client with a correctly signed token gets `ACCESS_REFUSED`, and the log shows `PLAIN login refused: user '<sub>' - invalid credentials` | The token's `sub` has no user in RabbitMQ. This backend only authenticates; permissions come from `internal`, so every token subject needs a user with vhost permissions. A token-only user needs no usable password: `rabbitmqctl add_user <sub> <anything>` then `rabbitmqctl clear_password <sub>`. |
| `PLAIN login refused: not a bearer token` | The credential was rejected by `internal` and did not start with `token:` — in practice a wrong password, or a token sent in the username field. The token belongs in the **password** field, prefixed with `token:`; the username may be anything, since the identity is the token's `sub`. |
| `PLAIN login refused: not a bearer token (it looks like a JWT without the token: prefix)` | The client sent the JWT as the password but without the `token:` prefix. Add the prefix on the client, or enable `accept_bare_jwt` (see [Tokens without the prefix](#tokens-without-the-prefix)). |
| `PLAIN login refused: invalid token signature` | The node verifies with a different key than the one that signed the token. Compare the `sha256:` fingerprint logged when the key is loaded against `sha256sum` of the intended key file, and across the nodes of a cluster. |
| With debug logging on, `failed authentication by backend rabbit_auth_backend_internal` appears before this backend's lines | Expected: `internal` is tried first and rejects the token as a password, then the chain reaches this backend. Follow one connection by its process id (`grep -F '<0.x.y>'`) to see how it ended. |
| No decision lines at all | Decisions are logged at debug level. `rabbitmqctl set_log_level debug` turns it on at runtime without a restart, `set_log_level info` turns it off. A connection only authenticates when it opens, so clients that are already connected produce no new lines until they reconnect. |

The `PLAIN login refused: ...` lines are logged at error level by RabbitMQ
itself, so they are visible without debug logging.

## Token format

A standard JWT whose payload carries at least `{"sub":"<username>"}`. The
client sends it in the password field prefixed with `token:`, e.g.
`token:eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhcHAxIn0.<signature>`.

### Tokens without the prefix

Some clients cannot add the `token:` prefix and send the bare JWT as the
password. Set `auth_aoptoken.accept_bare_jwt = true` to accept those as well.
It is off by default because it is rarely needed: the prefix is what makes a
token unambiguous. A credential is taken for a bare JWT only when it has the
shape of one — three dot-separated segments, the first a JSON header naming an
`alg` — and its signature and claims are then checked exactly as for a
prefixed token. An ordinary password is not mistaken for one.

With the setting off, a bare JWT is refused with its own reason,
`not a bearer token (it looks like a JWT without the token: prefix)`, so such
clients are easy to spot in the log even without debug logging.

### Signing algorithms

The signing algorithm is read from the JWT header:

| header `alg` | verified with |
|---|---|
| `HS256` / `HS384` / `HS512` | the symmetric secret (Pulsar's `tokenSecretKey` mode) |
| `RS256` / `RS384` / `RS512` | the RSA public key |
| `ES256` / `ES384` / `ES512` | the EC public key (Pulsar's `tokenPublicKey` mode) |
| `none`, anything else | rejected |

Claims are validated after the signature: `exp` and `nbf` are enforced when
present (with optional `leeway_seconds`), and `aud` is checked when `audience`
is configured. This matches Apache Pulsar's built-in token authentication,
which is JWT-based and unchanged in shape across Pulsar 2.x–4.x.

## Compatibility

The plugin is **not pinned to a RabbitMQ version**. It imposes no
`broker_version_requirements`, and its source uses only the
`rabbit_authn_backend` behaviour, the `#auth_user{}` record and RabbitMQ's log
domain — all unchanged across RabbitMQ 3.11–4.3 (the behaviour moved from
`rabbit_common` to `rabbit` in 4.2, with the same callback). The `3.12.14` seen
in `rebar.config` and the build notes is only the reference used to fetch
headers and to verify against; the compiled plugin loads on any 3.11–4.3
broker whose OTP matches the artifact (see the table below).

Verified end to end against running brokers — password login, token login,
bad signature, unknown subject, token-only user, key fingerprint and debug
logging — on RabbitMQ 3.12.14 (OTP 25 and 26), 4.0.9 (OTP 26) and 4.3.6
(OTP 27).

The binary `.ez` is tied to the **Erlang/OTP** it was compiled on. BEAM is
forward-compatible: code compiled on OTP *N* loads on OTP *N*, *N+1* and *N+2*
(a newer runtime loads older BEAM, not the reverse). Each release therefore
ships one `.ez` per OTP line — pick the one at or below your broker's OTP:

| your broker's OTP | use the asset |
|---|---|
| 25 | `…-otp25.ez` |
| 26 | `…-otp26.ez` |
| 27, 28 or 29 | `…-otp27.ez` (a newer runtime loads an older-built artifact) |

The prebuilt assets cover **OTP 25–29**, i.e. RabbitMQ 3.11 and 3.12 on OTP 25
through the latest 4.x. Check your broker's OTP with
`rabbitmqctl status | grep -i erlang`. If none matches, build from source
against your version (below).

## Use the prebuilt release (no build needed)

A ready-to-use `.ez` is attached to each GitHub release — grab the [latest one](https://github.com/martinx/rabbitmq-auth-backend-aoptoken/releases/latest), or browse [all releases](https://github.com/martinx/rabbitmq-auth-backend-aoptoken/releases). It is built per OTP line (see Compatibility above). Match your broker's OTP major version.

```sh
# 1. drop the plugin into the broker's plugins directory
cp rabbitmq_auth_backend_aoptoken-<version>-otp26.ez "$RABBITMQ_HOME/plugins/"   # pick the -otpNN matching your broker

# 2. enable it
rabbitmq-plugins enable rabbitmq_auth_backend_aoptoken

# 3. set the key and the auth chain in rabbitmq.conf as shown above,
#    then restart the node
rabbitmqctl shutdown && rabbitmq-server -detached

# 4. verify — same account, both credentials
rabbitmqctl authenticate_user <user> '<password>'
rabbitmqctl authenticate_user <user> 'token:<jwt>'
```

`rabbitmq-plugins list` should show `[E*] rabbitmq_auth_backend_aoptoken`.

> The `.ez` bundles compiled BEAM for one Erlang major version. If your broker
> runs a different Erlang, build from source (below) against that version.

## Build from source

`./build-ez.sh` produces the `.ez` for the Erlang/OTP it runs on, against the
`rabbit_common` (and, from 4.2, `rabbit`) shipped with a broker:

```sh
./build-ez.sh --rmq-release 3.12.14     # or: ./build-ez.sh <rmq>/plugins/rabbit_common-<version>
```

Quick compile for a smoke test (against a broker's shipped applications):

```sh
erlc -I <rmq>/plugins/rabbit_common-<version>/include \
     -pa <rmq>/plugins/rabbit_common-<version>/ebin \
     -pa <rmq>/plugins/rabbit-<version>/ebin \
     -o ebin src/rabbit_auth_backend_aoptoken.erl
```

## Tests

EUnit covers every supported algorithm, the claim checks, the rejection
paths (tampering, `alg: none`, algorithm confusion, expiry, audience,
missing configuration) and the optional bare-JWT path. Tokens are minted inside the suite, so the real
signature paths are exercised.

```sh
./run-tests.sh --rmq-release 3.13.7     # or: ./run-tests.sh <rabbit_common dir>
```

CI runs the suite against every supported RabbitMQ line at its latest patch
release — 3.11, 3.12, 3.13, 4.0, 4.1, 4.2 and 4.3 — each on an OTP that line
ships with, plus 3.12 on OTP 25 (the oldest runtime an artifact targets) and
4.3 on OTP 28 to catch a future runtime breaking the source.

## Install

1. Download the `.ez` for your broker's OTP line from the latest release (or
   build it yourself) and drop it into `plugins/`.
2. `rabbitmq-plugins enable rabbitmq_auth_backend_aoptoken`
3. Set `auth_aoptoken.key_file` and the auth chain in `rabbitmq.conf` as above.
4. Restart the node and verify with both a password client and a token client.

## Security notes

- The algorithm is taken from the token header and must be one of the
  supported families; `none` is always rejected.
- Symmetric and asymmetric keys are configured separately, so a public key can
  never be used as an HMAC secret (the classic JWT algorithm-confusion attack).
- HMAC comparison is constant-time.
- `accept_bare_jwt` changes only which credentials are recognised as tokens;
  a bare JWT is verified exactly like a prefixed one.
- `exp` / `nbf` are enforced when present. Tokens without `exp` do not expire —
  rotate keys or tokens according to your own policy.
- The signing key is read from configuration at runtime and is never embedded
  in the plugin.

## Trademarks

This is an independent community plugin. It is not affiliated with, endorsed
by or supported by Broadcom Inc. or the RabbitMQ team. RabbitMQ is a trademark
of Broadcom Inc.

## License

MIT. See [LICENSE](LICENSE).

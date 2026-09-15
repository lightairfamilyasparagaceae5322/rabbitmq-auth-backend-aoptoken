# rabbitmq-auth-backend-aoptoken

A RabbitMQ authentication backend that lets clients authenticate with a
**pre-issued HS256 JWT token** (an opaque `token:<jwt>` string placed in the
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
2. Otherwise this backend sees the `token:` prefix, verifies the JWT's HS256
   signature with a configured key, and takes the `sub` claim as the identity.
3. Authorization uses `internal` (the vhost permissions already defined for
   that identity).

## Configuration

The signing key is configurable via `advanced.config`, in this order of
precedence:

```erlang
[
  {rabbitmq_auth_backend_aoptoken, [
     %% pick ONE:
     {key_file,   "/etc/rabbitmq/token.key"}   %% raw key bytes read from a file
     %% {key_base64, "Jw..."}                   %% inline, base64-encoded
     %% {key,        <<"...">>}                 %% inline raw bytes
  ]}
].
```

The key is read once and cached; changing the config value reloads it. If no
key is configured, token logins are refused (password logins are unaffected).
The key never ships with the plugin.

## Token format

Standard JWT, `alg=HS256`, payload contains at least `{"sub":"<username>"}`.
The client sends it in the password field prefixed with `token:`, e.g.
`token:eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhcHAxIn0.<sig>`.

## Compatibility

The source is version-agnostic: it uses only the `rabbit_authn_backend`
behaviour and the `#auth_user{}` record, which are unchanged across RabbitMQ
3.8–4.0.

The binary `.ez` is tied to the **Erlang/OTP** it was compiled on. BEAM is
forward-compatible: code compiled on OTP *N* loads on OTP *N*, *N+1* and *N+2*
(a newer runtime loads older BEAM, not the reverse). Each release therefore
ships one `.ez` per OTP line — pick the one at or below your broker's OTP:

| your broker's OTP | use the asset | also covers |
|---|---|---|
| 25 | `…-otp25.ez` | RabbitMQ 3.12 |
| 26 | `…-otp26.ez` | RabbitMQ 3.12 / 3.13 / 4.0 |
| 27 | `…-otp27.ez` | RabbitMQ 4.0 |

Check your broker's OTP with `rabbitmqctl status | grep -i erlang`. If none
matches, build from source against your version (below).

## Use the prebuilt release (no build needed)

A ready-to-use `.ez` is attached to each [GitHub release](https://github.com/martinx/rabbitmq-auth-backend-aoptoken/releases). It is built per OTP line (see Compatibility above). Match your broker's OTP major version.

```sh
# 1. drop the plugin into the broker's plugins directory
cp rabbitmq_auth_backend_aoptoken-0.1.0-otp26.ez "$RABBITMQ_HOME/plugins/"

# 2. enable it
rabbitmq-plugins enable rabbitmq_auth_backend_aoptoken

# 3. point it at the signing key (advanced.config) and set the chain
#    (rabbitmq.conf) as shown above, then restart the node
rabbitmqctl shutdown && rabbitmq-server -detached

# 4. verify — same account, both credentials
rabbitmqctl authenticate_user <user> '<password>'
rabbitmqctl authenticate_user <user> 'token:<jwt>'
```

`rabbitmq-plugins list` should show `[E*] rabbitmq_auth_backend_aoptoken`.

> The `.ez` bundles compiled BEAM for one Erlang major version. If your broker
> runs a different Erlang, build from source (below) against that version.

## Build from source

This is a standard RabbitMQ plugin and must be built against the target broker
version's toolchain (see the RabbitMQ plugin development guide). It has been
compiled and tested against **RabbitMQ 3.12.14 / Erlang 26**.

Quick compile for a smoke test (against a broker's shipped `rabbit_common`):

```sh
erlc -I <rmq>/plugins/rabbit_common-3.12.14/include \
     -pa <rmq>/plugins/rabbit_common-3.12.14/ebin \
     -o ebin src/rabbit_auth_backend_aoptoken.erl
```

## Install

1. Build/package the plugin as `.ez` for your broker version and drop it into
   `plugins/`.
2. `rabbitmq-plugins enable rabbitmq_auth_backend_aoptoken`
3. Set `key_file` (advanced.config) and the auth chain (rabbitmq.conf) as above.
4. Restart the node and verify with both a password client and a token client.

## Security notes

- Uses constant-time comparison for the signature.
- The signing key never leaves the server; it is not embedded in the plugin.
- Tokens without an `exp` claim do not expire — rotate keys/tokens per your
  policy. Signature verification means captured tokens are honored only while
  the key is unchanged.

## License

MIT. See [LICENSE](LICENSE).

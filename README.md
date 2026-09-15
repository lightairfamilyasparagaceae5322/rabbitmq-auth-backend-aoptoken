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

The signing key is read from a file (raw key bytes, as used by the issuer):

```erlang
%% advanced.config
[
  {rabbitmq_auth_backend_aoptoken, [
     {key_file, "/etc/rabbitmq/token.key"}
  ]}
].
```

## Token format

Standard JWT, `alg=HS256`, payload contains at least `{"sub":"<username>"}`.
The client sends it in the password field prefixed with `token:`, e.g.
`token:eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhcHAxIn0.<sig>`.

## Build

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

Apache-2.0. See [LICENSE](LICENSE).

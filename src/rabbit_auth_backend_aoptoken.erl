%% RabbitMQ authentication backend for pre-issued JWT bearer tokens.
%%
%% Accepts clients that send a token in the AMQP password field, prefixed with
%% "token:" and carrying a JWT whose payload has a "sub" claim — the credential
%% style used by Apache Pulsar and AoP-based brokers. Such clients keep working
%% unchanged after migrating to native RabbitMQ, side by side with ordinary
%% username/password users on the same account.
%%
%% Authentication only: put it in a chain and delegate authorization to the
%% internal backend, so permissions keep coming from RabbitMQ's own database.
%%
%%   auth_backends.1 = internal
%%   auth_backends.2.authn = rabbit_auth_backend_aoptoken
%%   auth_backends.2.authz = internal
%%
%% The signing algorithm is taken from the JWT header:
%%
%%   HS256 / HS384 / HS512   symmetric, verified with a shared secret
%%                           (Pulsar's tokenSecretKey mode)
%%   RS256 / RS384 / RS512   RSA, verified with a public key
%%   ES256 / ES384 / ES512   ECDSA, verified with a public key
%%                           (Pulsar's tokenPublicKey mode)
%%
%% "none" and any other algorithm are rejected.
%%
%% Configuration (advanced.config), all optional except one key source:
%%
%%   {rabbitmq_auth_backend_aoptoken, [
%%      %% symmetric secret — one of:
%%      {key_file,          "/etc/rabbitmq/token.key"},
%%      {key_base64,        "..."},
%%      {key,               <<"...">>},
%%
%%      %% public key for RS*/ES* (PEM or DER SubjectPublicKeyInfo) — one of:
%%      {public_key_file,   "/etc/rabbitmq/token-public.pem"},
%%      {public_key_base64, "..."},
%%      {public_key,        <<"...">>},
%%
%%      {audience,       <<"my-cluster">>},  %% require a matching "aud" claim
%%      {leeway_seconds, 0}                  %% clock skew allowance for exp/nbf
%%   ]}
%%
%% Every authentication decision is reported at debug level, naming the
%% algorithm, the account the client connected as and the token's subject, so
%% a chain can be traced without a packet capture. Turn it on with
%%
%%   log.file.level = debug
%%
%% Tokens and keys are never written to the log, at any level: a presented
%% token is reported only by its size.
-module(rabbit_auth_backend_aoptoken).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/logging.hrl").
-include_lib("kernel/include/logger.hrl").

-behaviour(rabbit_authn_backend).

-export([user_login_authentication/2]).

-define(APP, rabbitmq_auth_backend_aoptoken).
-define(UNKNOWN_ALG, <<"(unknown)">>).
%% Log through Erlang's logger under RabbitMQ's global log domain: the routing
%% the rabbit_log module applied, which RabbitMQ deprecated in 4.1.
-define(LOG_META, #{domain => ?RMQLOG_DOMAIN_GLOBAL}).

%%----------------------------------------------------------------------------
%% Authentication
%%----------------------------------------------------------------------------

user_login_authentication(Username, AuthProps) ->
    case password(AuthProps) of
        {ok, <<"token:", Jwt/binary>>} ->
            ?LOG_DEBUG(
              "~ts: '~ts' presented a bearer token (~b bytes)",
              [?APP, Username, byte_size(Jwt)], ?LOG_META),
            case check_token(Jwt) of
                {ok, Subject, Alg} ->
                    %% The token's subject is the identity; the authorization
                    %% backend resolves its permissions.
                    ?LOG_DEBUG(
                      "~ts: accepted a ~ts token presented as '~ts';"
                      " authenticating as its subject '~ts'",
                      [?APP, Alg, Username, Subject], ?LOG_META),
                    {ok, #auth_user{username = Subject, tags = [], impl = none}};
                {refused, Reason, Alg} ->
                    ?LOG_DEBUG(
                      "~ts: refused a ~ts token presented as '~ts': ~ts",
                      [?APP, Alg, Username, Reason], ?LOG_META),
                    {refused, Reason, []};
                {misconfigured, Reason} ->
                    ?LOG_WARNING(
                      "~ts: cannot verify tokens: ~tp", [?APP, Reason],
                      ?LOG_META),
                    {refused, "token authentication is not configured", []}
            end;
        {ok, _NotAToken} ->
            %% Leave it to the next backend in the chain (typically internal).
            ?LOG_DEBUG(
              "~ts: '~ts' presented a password rather than a bearer token,"
              " leaving it to the rest of the chain",
              [?APP, Username], ?LOG_META),
            {refused, "not a bearer token", []};
        error ->
            ?LOG_DEBUG(
              "~ts: no credentials presented for '~ts'", [?APP, Username],
              ?LOG_META),
            {refused, "no credentials provided", []}
    end.

password(Props) when is_map(Props) ->
    case maps:find(password, Props) of
        {ok, V} -> {ok, to_binary(V)};
        error   -> error
    end;
password(Props) when is_list(Props) ->
    case lists:keyfind(password, 1, Props) of
        {password, V} -> {ok, to_binary(V)};
        false         -> error
    end;
password(_) ->
    error.

to_binary(B) when is_binary(B) -> B;
to_binary(L) when is_list(L)   -> iolist_to_binary(L);
to_binary(_)                   -> <<>>.

%%----------------------------------------------------------------------------
%% Token verification
%%----------------------------------------------------------------------------

%% {ok, Subject, Alg} | {refused, Reason, Alg} | {misconfigured, Reason}
%%
%% Alg is the algorithm named in the token header, reported purely so the
%% caller can say which one was involved when logging the outcome.
check_token(Jwt) ->
    try
        case binary:split(Jwt, <<".">>, [global]) of
            [HeaderSeg, PayloadSeg, SigSeg] ->
                Header = decode_json(HeaderSeg),
                Payload = decode_json(PayloadSeg),
                Alg = alg_name(Header),
                Signed = <<HeaderSeg/binary, ".", PayloadSeg/binary>>,
                Signature = base64url_decode(SigSeg),
                case verify_signature(Header, Signed, Signature) of
                    true  -> with_alg(check_claims(Payload), Alg);
                    false -> {refused, "invalid token signature", Alg};
                    {unsupported, _Raw} ->
                        %% Report the sanitized name, not the raw header value.
                        {refused, "unsupported token algorithm " ++
                             binary_to_list(Alg), Alg}
                end;
            _ ->
                {refused, "malformed token", ?UNKNOWN_ALG}
        end
    catch
        throw:{?APP, misconfigured, Reason} -> {misconfigured, Reason};
        _:_ -> {refused, "malformed token", ?UNKNOWN_ALG}
    end.

with_alg({ok, Subject}, Alg)     -> {ok, Subject, Alg};
with_alg({refused, Reason}, Alg) -> {refused, Reason, Alg}.

%% The header's "alg", reduced to something safe to put in a log line or hand
%% back to a client. It is read before any signature is checked, so it is
%% wholly attacker-controlled: cap its length and drop anything that is not a
%% plain identifier character, so a crafted token cannot flood the log or
%% forge a line break in it.
alg_name(Header) ->
    case maps:get(<<"alg">>, Header, undefined) of
        Alg when is_binary(Alg), Alg =/= <<>> ->
            case << <<C>> || <<C>> <= binary:part(Alg, 0, min(byte_size(Alg), 16)),
                             is_identifier_char(C) >> of
                <<>>      -> ?UNKNOWN_ALG;
                Sanitized -> Sanitized
            end;
        _ ->
            ?UNKNOWN_ALG
    end.

is_identifier_char(C) when C >= $a, C =< $z -> true;
is_identifier_char(C) when C >= $A, C =< $Z -> true;
is_identifier_char(C) when C >= $0, C =< $9 -> true;
is_identifier_char($-)                      -> true;
is_identifier_char($_)                      -> true;
is_identifier_char(_)                       -> false.

verify_signature(Header, Signed, Signature) ->
    case algorithm(Header) of
        {hmac, Digest} ->
            Expected = crypto:mac(hmac, Digest, symmetric_key(), Signed),
            constant_time_equal(Expected, Signature);
        {rsa, Digest} ->
            crypto:verify(rsa, Digest, Signed, Signature, rsa_public_key(),
                          [{rsa_padding, rsa_pkcs1_padding}]);
        {ecdsa, Digest} ->
            {Point, Curve} = ec_public_key(),
            crypto:verify(ecdsa, Digest, Signed, ecdsa_der_signature(Signature),
                          [Point, Curve]);
        {unsupported, Alg} ->
            {unsupported, Alg}
    end.

algorithm(Header) ->
    case maps:get(<<"alg">>, Header, undefined) of
        <<"HS256">> -> {hmac,  sha256};
        <<"HS384">> -> {hmac,  sha384};
        <<"HS512">> -> {hmac,  sha512};
        <<"RS256">> -> {rsa,   sha256};
        <<"RS384">> -> {rsa,   sha384};
        <<"RS512">> -> {rsa,   sha512};
        <<"ES256">> -> {ecdsa, sha256};
        <<"ES384">> -> {ecdsa, sha384};
        <<"ES512">> -> {ecdsa, sha512};
        Alg when is_binary(Alg) -> {unsupported, Alg};
        _ -> {unsupported, <<"(absent)">>}
    end.

%% Signature is valid at this point; validate the claims that bound its use.
check_claims(Payload) ->
    Now = os:system_time(second),
    Leeway = config(leeway_seconds, 0),
    case expired(Payload, Now, Leeway) of
        true  -> {refused, "token has expired"};
        false ->
            case not_yet_valid(Payload, Now, Leeway) of
                true  -> {refused, "token is not valid yet"};
                false ->
                    case audience_accepted(Payload) of
                        false -> {refused, "token audience mismatch"};
                        true  -> subject(Payload)
                    end
            end
    end.

expired(Payload, Now, Leeway) ->
    case maps:get(<<"exp">>, Payload, undefined) of
        Exp when is_number(Exp) -> Now > Exp + Leeway;
        _ -> false
    end.

not_yet_valid(Payload, Now, Leeway) ->
    case maps:get(<<"nbf">>, Payload, undefined) of
        Nbf when is_number(Nbf) -> Now + Leeway < Nbf;
        _ -> false
    end.

audience_accepted(Payload) ->
    case config(audience, undefined) of
        undefined -> true;
        Expected0 ->
            Expected = to_binary(Expected0),
            case maps:get(<<"aud">>, Payload, undefined) of
                Expected             -> true;
                L when is_list(L)    -> lists:member(Expected, L);
                _                    -> false
            end
    end.

subject(Payload) ->
    case maps:get(<<"sub">>, Payload, undefined) of
        Sub when is_binary(Sub), Sub =/= <<>> -> {ok, Sub};
        _ -> {refused, "token has no subject"}
    end.

decode_json(Segment) ->
    case rabbit_json:try_decode(base64url_decode(Segment)) of
        {ok, Map} when is_map(Map) -> Map;
        _ -> throw(malformed)
    end.

%%----------------------------------------------------------------------------
%% Keys
%%----------------------------------------------------------------------------

%% Shared secret for HS*: key | key_base64 | key_file.
symmetric_key() ->
    resolve(symmetric_key,
            [{key, inline}, {key_base64, base64}, {key_file, file}],
            fun(Bytes) -> Bytes end,
            no_symmetric_key_configured).

%% Public key for RS*/ES*: public_key | public_key_base64 | public_key_file.
public_key() ->
    resolve(public_key,
            [{public_key, inline}, {public_key_base64, base64},
             {public_key_file, file}],
            fun decode_public_key/1,
            no_public_key_configured).

rsa_public_key() ->
    case public_key() of
        {'RSAPublicKey', Modulus, Exponent} -> [Exponent, Modulus];
        _ -> misconfigured(configured_public_key_is_not_rsa)
    end.

ec_public_key() ->
    case public_key() of
        {{'ECPoint', Point}, {namedCurve, Oid}} -> {Point, named_curve(Oid)};
        _ -> misconfigured(configured_public_key_is_not_ec)
    end.

named_curve({1, 2, 840, 10045, 3, 1, 7}) -> secp256r1;
named_curve({1, 3, 132, 0, 34})          -> secp384r1;
named_curve({1, 3, 132, 0, 35})          -> secp521r1;
named_curve(Oid)                         -> misconfigured({unsupported_curve, Oid}).

%% Resolve a key from the first configured source, caching the result in
%% persistent_term keyed by the source, so files are not re-read on every
%% authentication and a configuration change is picked up automatically.
resolve(CacheName, Sources, Transform, MissingReason) ->
    Source = case first_configured(Sources) of
                 undefined -> misconfigured(MissingReason);
                 Found     -> Found
             end,
    CacheKey = {?MODULE, CacheName},
    case persistent_term:get(CacheKey, undefined) of
        {Source, Value} ->
            Value;
        _ ->
            Bytes = load_bytes(Source),
            Value = Transform(Bytes),
            persistent_term:put(CacheKey, {Source, Value}),
            report_key(CacheName, Source, Bytes),
            Value
    end.

%% Say which key material the node ended up using, once per load. Operators
%% otherwise have no way to tell whether the running node picked up the key
%% they think it did: the configuration only names a path or an encoded
%% string, not the bytes behind it. The fingerprint is the first four bytes of
%% its SHA-256, which identifies the key without disclosing it — compare it
%% against `sha256sum` of the intended file, or across the nodes of a cluster.
report_key(CacheName, {Kind, Value}, Bytes) ->
    ?LOG_INFO("~ts: loaded ~ts from ~ts (~b bytes, sha256:~ts)",
              [?APP, key_label(CacheName), source_label(Kind, Value),
               byte_size(Bytes), fingerprint(Bytes)], ?LOG_META).

key_label(symmetric_key) -> "symmetric key";
key_label(public_key)    -> "public key".

%% Never echo the key itself: an inline source is named, not printed.
source_label(file,   Path) -> Path;
source_label(inline, _)    -> <<"an inline value">>;
source_label(base64, _)    -> <<"an inline base64 value">>.

fingerprint(Bytes) ->
    <<Short:4/binary, _/binary>> = crypto:hash(sha256, Bytes),
    iolist_to_binary(string:lowercase(binary:encode_hex(Short))).

first_configured([]) ->
    undefined;
first_configured([{Name, Kind} | Rest]) ->
    case application:get_env(?APP, Name) of
        {ok, Value} -> {Kind, to_binary(Value)};
        _           -> first_configured(Rest)
    end.

load_bytes({inline, Bytes}) -> Bytes;
load_bytes({base64, Value}) -> base64:decode(Value);
load_bytes({file, Path}) ->
    case file:read_file(Path) of
        {ok, Bytes}     -> Bytes;
        {error, Reason} -> misconfigured({cannot_read_key_file, Path, Reason})
    end.

%% Accepts a PEM public key or a DER-encoded SubjectPublicKeyInfo.
decode_public_key(Bytes) ->
    try
        case binary:match(Bytes, <<"-----BEGIN">>) of
            nomatch ->
                public_key:der_decode('SubjectPublicKeyInfo', Bytes);
            _ ->
                [Entry | _] = public_key:pem_decode(Bytes),
                public_key:pem_entry_decode(Entry)
        end
    catch
        _:_ -> misconfigured(cannot_decode_public_key)
    end.

misconfigured(Reason) ->
    throw({?APP, misconfigured, Reason}).

config(Name, Default) ->
    application:get_env(?APP, Name, Default).

%%----------------------------------------------------------------------------
%% Encoding helpers
%%----------------------------------------------------------------------------

base64url_decode(Bin) ->
    Padded = case byte_size(Bin) rem 4 of
                 0 -> Bin;
                 N -> <<Bin/binary, (binary:copy(<<"=">>, 4 - N))/binary>>
             end,
    base64:decode(binary:replace(
                    binary:replace(Padded, <<"-">>, <<"+">>, [global]),
                    <<"_">>, <<"/">>, [global])).

%% JWS carries an ECDSA signature as the raw R||S pair; crypto:verify expects
%% a DER SEQUENCE of two INTEGERs.
ecdsa_der_signature(Signature) ->
    Half = byte_size(Signature) div 2,
    <<R:Half/binary, S:Half/binary>> = Signature,
    Body = <<(der_integer(R))/binary, (der_integer(S))/binary>>,
    <<16#30, (der_length(byte_size(Body)))/binary, Body/binary>>.

der_integer(Bin) ->
    Value = case strip_leading_zeros(Bin) of
                %% DER integers are signed: a leading bit of 1 needs a 0 byte.
                <<First, _/binary>> = V when First >= 16#80 -> <<0, V/binary>>;
                <<>> -> <<0>>;
                V -> V
            end,
    <<16#02, (der_length(byte_size(Value)))/binary, Value/binary>>.

strip_leading_zeros(<<0, Rest/binary>>) when byte_size(Rest) > 0 ->
    strip_leading_zeros(Rest);
strip_leading_zeros(Bin) ->
    Bin.

der_length(Length) when Length < 16#80  -> <<Length>>;
der_length(Length) when Length < 16#100 -> <<16#81, Length>>;
der_length(Length)                      -> <<16#82, Length:16>>.

constant_time_equal(A, B) when byte_size(A) =/= byte_size(B) ->
    false;
constant_time_equal(A, B) ->
    constant_time_equal(A, B, 0).

constant_time_equal(<<>>, <<>>, Acc) ->
    Acc =:= 0;
constant_time_equal(<<X, A/binary>>, <<Y, B/binary>>, Acc) ->
    constant_time_equal(A, B, Acc bor (X bxor Y)).

%% EUnit suite for rabbit_auth_backend_aoptoken.
%%
%% Tokens are minted inside the tests (no fixtures, no external tooling), so
%% the suite exercises the real signature paths for every supported algorithm.
-module(rabbit_auth_backend_aoptoken_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("public_key/include/public_key.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-define(APP, rabbitmq_auth_backend_aoptoken).
-define(SECRET, <<"a-32-byte-test-secret-0123456789">>).
-define(USER, <<"app1">>).

%%----------------------------------------------------------------------------
%% Fixture
%%----------------------------------------------------------------------------

setup() ->
    application:load(?APP),
    reset(),
    RSA = public_key:generate_key({rsa, 2048, 65537}),
    EC = public_key:generate_key({namedCurve, secp256r1}),
    #{rsa => RSA, ec => EC}.

cleanup(_) ->
    reset().

reset() ->
    persistent_term:erase({rabbit_auth_backend_aoptoken, symmetric_key}),
    persistent_term:erase({rabbit_auth_backend_aoptoken, public_key}),
    [application:unset_env(?APP, K)
     || K <- [key, key_base64, key_file, public_key, public_key_base64,
              public_key_file, audience, leeway_seconds, accept_bare_jwt]],
    ok.

use_secret() ->
    reset(),
    application:set_env(?APP, key, ?SECRET).

use_public_key(Key) ->
    reset(),
    application:set_env(?APP, public_key, public_pem(Key)).

all_test_() ->
    {setup, fun setup/0, fun cleanup/1,
     fun(Keys) ->
        [ {"HS256 is accepted",            fun() -> hs_accepted(sha256, <<"HS256">>) end}
        , {"HS384 is accepted",            fun() -> hs_accepted(sha384, <<"HS384">>) end}
        , {"HS512 is accepted",            fun() -> hs_accepted(sha512, <<"HS512">>) end}
        , {"RS256 is accepted",            fun() -> rs_accepted(Keys, sha256, <<"RS256">>) end}
        , {"RS384 is accepted",            fun() -> rs_accepted(Keys, sha384, <<"RS384">>) end}
        , {"RS512 is accepted",            fun() -> rs_accepted(Keys, sha512, <<"RS512">>) end}
        , {"ES256 is accepted",            fun() -> es_accepted(Keys) end}
        , {"the subject becomes the identity", fun subject_is_identity/0}
        , {"a wrong secret is refused",    fun wrong_secret/0}
        , {"a tampered payload is refused", fun tampered_payload/0}
        , {"a tampered signature is refused", fun tampered_signature/0}
        , {"alg none is refused",          fun alg_none/0}
        , {"an unsupported alg is refused", fun unsupported_alg/0}
        , {"a hostile alg cannot flood or forge the log", fun hostile_alg_is_bounded/0}
        , {"an unprintable alg falls back to a placeholder", fun unprintable_alg_falls_back/0}
        , {"a malformed token reports no algorithm", fun malformed_reports_no_algorithm/0}
        , {"a public key cannot be used as an HMAC secret", fun alg_confusion/0}
        , {"an expired token is refused",  fun expired/0}
        , {"leeway tolerates a just-expired token", fun expiry_leeway/0}
        , {"a not-yet-valid token is refused", fun not_yet_valid/0}
        , {"a matching audience is accepted", fun audience_match/0}
        , {"a mismatched audience is refused", fun audience_mismatch/0}
        , {"a missing audience is refused when one is required", fun audience_missing/0}
        , {"a token without a subject is refused", fun no_subject/0}
        , {"a malformed token is refused", fun malformed/0}
        , {"a non-token password falls through", fun not_a_token/0}
        , {"absent credentials are refused", fun no_password/0}
        , {"an unconfigured key refuses rather than crashes", fun no_key_configured/0}
        , {"a base64 secret is accepted",  fun secret_from_base64/0}
        , {"a secret file is accepted",    fun secret_from_file/0}
        , {"changing the key at runtime takes effect", fun key_change_takes_effect/0}
        , {"props may be a map or a list", fun props_shapes/0}
        , {"a bare JWT is refused by default, with a distinct reason", fun bare_jwt_off/0}
        , {"a bare JWT is accepted when enabled", fun bare_jwt_on/0}
        , {"an enabled bare JWT still needs a valid signature", fun bare_jwt_bad_signature/0}
        , {"an ordinary password is unaffected by accept_bare_jwt", fun bare_jwt_password_unaffected/0}
        , {"a dotted password without a JWT header is not taken for one", fun bare_jwt_lookalike/0}
        ]
     end}.

%%----------------------------------------------------------------------------
%% Cases
%%----------------------------------------------------------------------------

hs_accepted(Digest, Alg) ->
    use_secret(),
    ?assertEqual({ok, ?USER}, auth(hs_token(Digest, Alg, #{<<"sub">> => ?USER}))).

rs_accepted(#{rsa := Key}, Digest, Alg) ->
    use_public_key(Key),
    ?assertEqual({ok, ?USER}, auth(rs_token(Key, Digest, Alg, #{<<"sub">> => ?USER}))).

es_accepted(#{ec := Key}) ->
    use_public_key(Key),
    ?assertEqual({ok, ?USER}, auth(es_token(Key, sha256, <<"ES256">>, #{<<"sub">> => ?USER}))).

subject_is_identity() ->
    use_secret(),
    %% The login name is ignored; the token's subject wins.
    Token = hs_token(sha256, <<"HS256">>, #{<<"sub">> => <<"real-identity">>}),
    ?assertEqual({ok, <<"real-identity">>},
                 auth(<<"whatever-the-client-typed">>, Token)).

wrong_secret() ->
    reset(),
    application:set_env(?APP, key, <<"not-the-right-secret-0123456789ab">>),
    ?assertMatch(refused, auth(hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}))).

tampered_payload() ->
    use_secret(),
    Token = hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}),
    [H, _P, S] = binary:split(Token, <<".">>, [global]),
    Forged = segment(#{<<"sub">> => <<"attacker">>}),
    ?assertMatch(refused, auth(<<H/binary, ".", Forged/binary, ".", S/binary>>)).

tampered_signature() ->
    use_secret(),
    Token = hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}),
    [H, P, S] = binary:split(Token, <<".">>, [global]),
    %% Flip a byte in the middle: the last base64url character carries only
    %% two significant bits, so editing it can decode to the same signature.
    Half = byte_size(S) div 2,
    <<Head:Half/binary, C:8, Tail/binary>> = S,
    Flipped = case C of $A -> $B; _ -> $A end,
    Bad = <<Head/binary, Flipped:8, Tail/binary>>,
    ?assertMatch(refused, auth(<<H/binary, ".", P/binary, ".", Bad/binary>>)).

alg_none() ->
    use_secret(),
    Token = <<(segment(#{<<"alg">> => <<"none">>}))/binary, ".",
              (segment(#{<<"sub">> => ?USER}))/binary, ".">>,
    ?assertMatch(refused, auth(Token)).

unsupported_alg() ->
    use_secret(),
    ?assertMatch(refused, auth(hs_token(sha256, <<"PS256">>, #{<<"sub">> => ?USER}))).

%% "alg" is read from the header before any signature has been checked, so it
%% is wholly attacker-controlled, and it reaches both the log and the refusal
%% handed back to the client. A crafted one must not be able to flood either
%% or forge a line break in the log.
hostile_alg_is_bounded() ->
    use_secret(),
    Hostile = <<"HS256 forged log line ", (binary:copy(<<"A">>, 4096))/binary>>,
    Reason = refusal_reason(hs_token(sha256, Hostile, #{<<"sub">> => ?USER})),
    %% still recognised as an algorithm problem, not degraded to "malformed"
    ?assertMatch("unsupported token algorithm" ++ _, Reason),
    ?assert(length(Reason) < 64),
    ?assertEqual(nomatch, binary:match(list_to_binary(Reason), <<"\n">>)).

%% An "alg" with nothing identifier-like left in it degrades to a placeholder
%% rather than an empty or raw value.
unprintable_alg_falls_back() ->
    use_secret(),
    ?assertEqual("unsupported token algorithm (unknown)",
                 refusal_reason(hs_token(sha256, <<"!@#$%^&*()">>,
                                         #{<<"sub">> => ?USER}))).

%% A malformed token reports a placeholder algorithm instead of crashing on
%% one that was never parsed.
malformed_reports_no_algorithm() ->
    use_secret(),
    ?assertEqual("malformed token", refusal_reason(<<"not.a.jwt">>)).

%% The classic JWT attack: sign with the RSA public key as an HMAC secret and
%% declare HS256. Symmetric and asymmetric keys are configured separately, so
%% the public key is never reachable as a MAC secret.
alg_confusion() ->
    #{rsa := Key} = setup_keys(),
    use_public_key(Key),
    Pem = public_pem(Key),
    Header = segment(#{<<"alg">> => <<"HS256">>}),
    Payload = segment(#{<<"sub">> => ?USER}),
    Signed = <<Header/binary, ".", Payload/binary>>,
    Sig = base64url(crypto:mac(hmac, sha256, Pem, Signed)),
    ?assertMatch(refused, auth(<<Signed/binary, ".", Sig/binary>>)).

expired() ->
    use_secret(),
    Past = os:system_time(second) - 60,
    ?assertMatch(refused, auth(hs_token(sha256, <<"HS256">>,
                                        #{<<"sub">> => ?USER, <<"exp">> => Past}))).

expiry_leeway() ->
    use_secret(),
    application:set_env(?APP, leeway_seconds, 120),
    Past = os:system_time(second) - 60,
    ?assertEqual({ok, ?USER},
                 auth(hs_token(sha256, <<"HS256">>,
                               #{<<"sub">> => ?USER, <<"exp">> => Past}))),
    application:unset_env(?APP, leeway_seconds).

not_yet_valid() ->
    use_secret(),
    Future = os:system_time(second) + 600,
    ?assertMatch(refused, auth(hs_token(sha256, <<"HS256">>,
                                        #{<<"sub">> => ?USER, <<"nbf">> => Future}))).

audience_match() ->
    use_secret(),
    application:set_env(?APP, audience, <<"cluster-a">>),
    ?assertEqual({ok, ?USER},
                 auth(hs_token(sha256, <<"HS256">>,
                               #{<<"sub">> => ?USER, <<"aud">> => <<"cluster-a">>}))).

audience_mismatch() ->
    use_secret(),
    application:set_env(?APP, audience, <<"cluster-a">>),
    ?assertMatch(refused,
                 auth(hs_token(sha256, <<"HS256">>,
                               #{<<"sub">> => ?USER, <<"aud">> => <<"cluster-b">>}))).

audience_missing() ->
    use_secret(),
    application:set_env(?APP, audience, <<"cluster-a">>),
    ?assertMatch(refused, auth(hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}))).

no_subject() ->
    use_secret(),
    ?assertMatch(refused, auth(hs_token(sha256, <<"HS256">>, #{<<"foo">> => <<"bar">>}))).

malformed() ->
    use_secret(),
    ?assertMatch(refused, auth(<<"not.a.valid.jwt">>)),
    ?assertMatch(refused, auth(<<"onlyonesegment">>)).

not_a_token() ->
    use_secret(),
    %% A plain password is left to the next backend in the chain.
    ?assertMatch(refused, call(?USER, <<"just-a-password">>)).

no_password() ->
    use_secret(),
    ?assertMatch(refused,
                 normalise(rabbit_auth_backend_aoptoken:user_login_authentication(?USER, []))).

no_key_configured() ->
    reset(),
    ?assertMatch(refused, auth(hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}))).

%% The key is cached, but keyed by its source: changing the configuration must
%% be picked up on the next authentication, with no restart and no cache reset.
%% This is what lets an operator rotate a key, or correct a wrong one, without
%% dropping a single connection.
key_change_takes_effect() ->
    use_secret(),
    Token = hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}),
    ?assertEqual({ok, ?USER}, auth(Token)),
    %% point at a different secret without touching the cache
    application:set_env(?APP, key, <<"a-different-32-byte-secret-01234">>),
    ?assertMatch(refused, auth(Token)),
    %% and back again
    application:set_env(?APP, key, ?SECRET),
    ?assertEqual({ok, ?USER}, auth(Token)).

secret_from_base64() ->
    reset(),
    application:set_env(?APP, key_base64, binary_to_list(base64:encode(?SECRET))),
    ?assertEqual({ok, ?USER}, auth(hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}))).

secret_from_file() ->
    reset(),
    Path = filename:join(test_dir(), "secret.key"),
    ok = file:write_file(Path, ?SECRET),
    application:set_env(?APP, key_file, Path),
    ?assertEqual({ok, ?USER}, auth(hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}))),
    file:delete(Path).

props_shapes() ->
    use_secret(),
    Token = <<"token:", (hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}))/binary>>,
    AsList = rabbit_auth_backend_aoptoken:user_login_authentication(?USER, [{password, Token}]),
    AsMap = rabbit_auth_backend_aoptoken:user_login_authentication(?USER, #{password => Token}),
    ?assertEqual({ok, ?USER}, normalise(AsList)),
    ?assertEqual({ok, ?USER}, normalise(AsMap)).

%% A JWT sent without the "token:" prefix is refused unless the operator opted
%% in, and the refusal names that case, so the error line RabbitMQ writes on its
%% own tells it apart from an ordinary wrong password.
bare_jwt_off() ->
    use_secret(),
    Jwt = hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}),
    ?assertEqual(refused, call(?USER, Jwt)),
    Reason = reason(Jwt),
    ?assertNotEqual(nomatch, string:find(Reason, "not a bearer token")),
    ?assertNotEqual(nomatch, string:find(Reason, "looks like a JWT")).

bare_jwt_on() ->
    use_secret(),
    application:set_env(?APP, accept_bare_jwt, true),
    Jwt = hs_token(sha256, <<"HS256">>, #{<<"sub">> => <<"real-identity">>}),
    ?assertEqual({ok, <<"real-identity">>}, call(<<"any-login">>, Jwt)).

bare_jwt_bad_signature() ->
    reset(),
    application:set_env(?APP, key, <<"not-the-right-secret-0123456789ab">>),
    application:set_env(?APP, accept_bare_jwt, true),
    Jwt = hs_token(sha256, <<"HS256">>, #{<<"sub">> => ?USER}),
    ?assertEqual(refused, call(?USER, Jwt)),
    ?assertEqual("invalid token signature", reason(Jwt)).

bare_jwt_password_unaffected() ->
    use_secret(),
    application:set_env(?APP, accept_bare_jwt, true),
    ?assertEqual("not a bearer token", reason(<<"correct horse battery staple">>)).

bare_jwt_lookalike() ->
    use_secret(),
    application:set_env(?APP, accept_bare_jwt, true),
    ?assertEqual("not a bearer token", reason(<<"first.second.third">>)),
    ?assertEqual("not a bearer token", reason(<<"v1.2.3">>)).

%%----------------------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------------------

setup_keys() ->
    #{rsa => public_key:generate_key({rsa, 2048, 65537})}.

auth(Token) -> auth(?USER, Token).

auth(Login, Token) -> call(Login, <<"token:", Token/binary>>).

%% The refusal text as the broker and the client see it, before normalise/1
%% throws it away.
refusal_reason(Token) ->
    {refused, Reason, []} =
        rabbit_auth_backend_aoptoken:user_login_authentication(
          ?USER, [{password, <<"token:", Token/binary>>}]),
    Reason.

%% The refusal text for a raw password, as RabbitMQ logs it.
reason(Password) ->
    {refused, Reason, []} =
        rabbit_auth_backend_aoptoken:user_login_authentication(
          ?USER, [{password, Password}]),
    Reason.

call(Login, Password) ->
    normalise(rabbit_auth_backend_aoptoken:user_login_authentication(
                Login, [{password, Password}])).

normalise({ok, #auth_user{username = U}}) -> {ok, U};
normalise({refused, _, _})                -> refused;
normalise(Other)                          -> Other.

hs_token(Digest, Alg, Claims) ->
    Signed = signing_input(Alg, Claims),
    Sig = base64url(crypto:mac(hmac, Digest, ?SECRET, Signed)),
    <<Signed/binary, ".", Sig/binary>>.

rs_token(#'RSAPrivateKey'{modulus = N, publicExponent = E, privateExponent = D},
         Digest, Alg, Claims) ->
    Signed = signing_input(Alg, Claims),
    Sig = base64url(crypto:sign(rsa, Digest, Signed, [E, N, D])),
    <<Signed/binary, ".", Sig/binary>>.

es_token(#'ECPrivateKey'{privateKey = Priv}, Digest, Alg, Claims) ->
    Signed = signing_input(Alg, Claims),
    Der = crypto:sign(ecdsa, Digest, Signed, [Priv, secp256r1]),
    Sig = base64url(der_to_jws(Der, 32)),
    <<Signed/binary, ".", Sig/binary>>.

signing_input(Alg, Claims) ->
    Header = segment(#{<<"alg">> => Alg, <<"typ">> => <<"JWT">>}),
    Payload = segment(Claims),
    <<Header/binary, ".", Payload/binary>>.

segment(Map) -> base64url(rabbit_json:encode(Map)).

public_pem(#'RSAPrivateKey'{modulus = N, publicExponent = E}) ->
    pem(public_key:der_encode('SubjectPublicKeyInfo',
          public_key:der_decode('SubjectPublicKeyInfo',
            public_key:der_encode('SubjectPublicKeyInfo',
              spki(#'RSAPublicKey'{modulus = N, publicExponent = E})))));
public_pem(#'ECPrivateKey'{publicKey = Point, parameters = Params}) ->
    pem(public_key:der_encode('SubjectPublicKeyInfo',
          spki({#'ECPoint'{point = Point}, Params}))).

spki(Key) ->
    Entry = public_key:pem_entry_encode('SubjectPublicKeyInfo', Key),
    {'SubjectPublicKeyInfo', Der, not_encrypted} = Entry,
    public_key:der_decode('SubjectPublicKeyInfo', Der).

pem(Der) ->
    public_key:pem_encode([{'SubjectPublicKeyInfo', Der, not_encrypted}]).

%% DER SEQUENCE(INTEGER r, INTEGER s) -> fixed-width r||s, as JWS wants.
der_to_jws(<<16#30, Rest0/binary>>, Width) ->
    Rest = strip_der_length(Rest0),
    {R, Rest1} = der_int(Rest),
    {S, <<>>} = der_int(Rest1),
    <<(pad(R, Width))/binary, (pad(S, Width))/binary>>.

strip_der_length(<<L, Rest/binary>>) when L < 16#80 -> Rest;
strip_der_length(<<16#81, _, Rest/binary>>) -> Rest;
strip_der_length(<<16#82, _:16, Rest/binary>>) -> Rest.

der_int(<<16#02, Len, Value:Len/binary, Rest/binary>>) -> {Value, Rest}.

pad(Bin, Width) when byte_size(Bin) > Width ->
    binary:part(Bin, byte_size(Bin) - Width, Width);
pad(Bin, Width) ->
    <<0:((Width - byte_size(Bin)) * 8), Bin/binary>>.

base64url(Bin) ->
    NoPad = binary:replace(base64:encode(Bin), <<"=">>, <<>>, [global]),
    binary:replace(binary:replace(NoPad, <<"+">>, <<"-">>, [global]),
                   <<"/">>, <<"_">>, [global]).

test_dir() ->
    Dir = filename:join("_build", "test-tmp"),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% RabbitMQ authentication backend for pre-issued HS256 JWT tokens.
%%
%% Accepts clients that send an opaque bearer token in the AMQP password
%% field, prefixed with "token:" and carrying a minimal JWT whose payload is
%% {"sub": "<username>"} (the credential style used by Pulsar/AoP-based
%% brokers). It lets such clients keep working unchanged after migrating to
%% native RabbitMQ, side by side with normal username/password users.
%%
%% - authn only; delegate authz to rabbit_auth_backend_internal in the chain
%% - signing key is configurable: {rabbitmq_auth_backend_aoptoken, key_file}
%% - identity is taken from the token's "sub" claim
%%
%% Config example (advanced.config):
%%   {rabbitmq_auth_backend_aoptoken, [{key_file, "/etc/rabbitmq/token.key"}]}
%% Chain (rabbitmq.conf):
%%   auth_backends.1 = internal
%%   auth_backends.2.authn = rabbit_auth_backend_aoptoken
%%   auth_backends.2.authz = internal
-module(rabbit_auth_backend_aoptoken).
-include_lib("rabbit_common/include/rabbit.hrl").
-behaviour(rabbit_authn_backend).
-export([user_login_authentication/2]).

user_login_authentication(_Username, AuthProps) ->
    case get_password(AuthProps) of
        {ok, Pwd} ->
            case strip_token(Pwd) of
                {ok, Jwt} ->
                    case verify(Jwt, key()) of
                        {ok, Sub} ->
                            %% 身份取 token 的 sub（AoP 语义）
                            {ok, #auth_user{username = Sub, tags = [], impl = none}};
                        error ->
                            {refused, "AoP token 签名校验失败", []}
                    end;
                notoken ->
                    %% 不是 token，交给链上其它后端（如 internal 账号密码）
                    {refused, "not an AoP token", []}
            end;
        error ->
            {refused, "no password provided", []}
    end.

get_password(P) when is_map(P) ->
    case maps:find(password, P) of {ok,V} -> {ok, to_bin(V)}; error -> error end;
get_password(P) when is_list(P) ->
    case lists:keyfind(password, 1, P) of {password,V} -> {ok, to_bin(V)}; false -> error end;
get_password(_) -> error.

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(_) -> <<>>.

strip_token(<<"token:", Rest/binary>>) -> {ok, Rest};
strip_token(_) -> notoken.

key() ->
    Path = application:get_env(rabbitmq_auth_backend_aoptoken, key_file, undefined),
    {ok, Bin} = file:read_file(Path),
    Bin.

verify(Jwt, Key) ->
    case binary:split(Jwt, <<".">>, [global]) of
        [H, P, S] ->
            Signing = <<H/binary, ".", P/binary>>,
            Expected = b64url(crypto:mac(hmac, sha256, Key, Signing)),
            case consttime_eq(Expected, S) of
                true  -> sub_of(P);
                false -> error
            end;
        _ -> error
    end.

sub_of(PayloadSeg) ->
    Json = b64url_decode(PayloadSeg),
    case re:run(Json, "\"sub\"\\s*:\\s*\"([^\"]+)\"", [{capture,[1],binary}]) of
        {match, [Sub]} -> {ok, Sub};
        _ -> error
    end.

%% base64url 编码（无填充）
b64url(Bin) ->
    B = base64:encode(Bin),
    NoPad = binary:replace(B, <<"=">>, <<>>, [global]),
    binary:replace(binary:replace(NoPad, <<"+">>, <<"-">>, [global]), <<"/">>, <<"_">>, [global]).

b64url_decode(Bin) ->
    B0 = binary:replace(binary:replace(Bin, <<"-">>, <<"+">>, [global]), <<"_">>, <<"/">>, [global]),
    Pad = case byte_size(B0) rem 4 of 0 -> <<>>; N -> binary:copy(<<"=">>, 4 - N) end,
    base64:decode(<<B0/binary, Pad/binary>>).

consttime_eq(A, B) when byte_size(A) =/= byte_size(B) -> false;
consttime_eq(A, B) -> consttime_eq(A, B, 0).
consttime_eq(<<>>, <<>>, Acc) -> Acc =:= 0;
consttime_eq(<<X,Ra/binary>>, <<Y,Rb/binary>>, Acc) ->
    consttime_eq(Ra, Rb, Acc bor (X bxor Y)).

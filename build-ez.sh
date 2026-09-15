#!/bin/bash
# 构建可直接安装的 .ez 插件包。
# 用法:
#   ./build-ez.sh <rabbit_common 目录>   使用本地 RabbitMQ 的 plugins/rabbit_common-<版本>
#   ./build-ez.sh                        无参数时用 rebar3 从 hex 拉取 rabbit_common
# 产物: _build/<app>-<vsn>-otp<OTP>.ez （按编译所用 OTP 大版本命名）
set -euo pipefail
APP=rabbitmq_auth_backend_aoptoken
VSN=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' src/${APP}.app.src)
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')

RC="${1:-}"
if [ -z "${RC}" ]; then
  echo ">> 无本地 rabbit_common，改用 rebar3 拉取"
  rebar3 compile >/dev/null
  RC=$(ls -d _build/default/lib/rabbit_common)
fi
echo ">> OTP ${OTP} · rabbit_common: ${RC}"

OUT="_build/${APP}-${VSN}"
rm -rf "${OUT}"; mkdir -p "${OUT}/ebin"
erlc -I "${RC}/include" -pa "${RC}/ebin" -o "${OUT}/ebin" src/rabbit_auth_backend_aoptoken.erl
sed 's/{modules, \[\]}/{modules, [rabbit_auth_backend_aoptoken]}/' \
    src/${APP}.app.src > "${OUT}/ebin/${APP}.app"
EZ="${APP}-${VSN}-otp${OTP}.ez"
( cd _build && rm -f "${EZ}" && zip -qr "${EZ}" "${APP}-${VSN}" )
echo ">> 产物: _build/${EZ}"

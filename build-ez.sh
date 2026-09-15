#!/bin/bash
# 构建可直接安装的 .ez 插件包。
# 用法: ./build-ez.sh <path-to-rabbit_common-VSN>   (即 RabbitMQ 的 plugins/rabbit_common-<版本> 目录)
set -euo pipefail
APP=rabbitmq_auth_backend_aoptoken
VSN=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' src/${APP}.app.src)
RC="${1:?用法: ./build-ez.sh <rabbit_common 目录>}"
OUT="_build/${APP}-${VSN}"
rm -rf _build && mkdir -p "${OUT}/ebin"
echo ">> 编译 (OTP $(erl -noshell -eval 'io:format(erlang:system_info(otp_release)),halt().'))"
erlc -I "${RC}/include" -pa "${RC}/ebin" -o "${OUT}/ebin" src/rabbit_auth_backend_aoptoken.erl
# 生成 .app（由 .app.src 补上 modules）
sed 's/{modules, \[\]}/{modules, [rabbit_auth_backend_aoptoken]}/' \
    src/${APP}.app.src > "${OUT}/ebin/${APP}.app"
( cd _build && zip -qr "${APP}-${VSN}.ez" "${APP}-${VSN}" )
echo ">> 产物: _build/${APP}-${VSN}.ez"
unzip -l "_build/${APP}-${VSN}.ez"

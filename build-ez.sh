#!/bin/bash
# Build an installable .ez plugin package.
# Usage:
#   ./build-ez.sh <rabbit_common dir>   use a local RabbitMQ plugins/rabbit_common-<vsn>
#   ./build-ez.sh                       no arg: fetch rabbit_common from hex via rebar3
# Output: _build/<app>-<vsn>-otp<OTP>.ez  (named by the OTP major it was built on)
set -euo pipefail
APP=rabbitmq_auth_backend_aoptoken
VSN=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' src/${APP}.app.src)
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')

RC="${1:-}"
if [ -z "${RC}" ]; then
  echo ">> no local rabbit_common; fetching via rebar3"
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
echo ">> built: _build/${EZ}"

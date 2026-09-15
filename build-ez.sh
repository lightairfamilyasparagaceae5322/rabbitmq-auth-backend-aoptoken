#!/bin/bash
# Build an installable .ez plugin package.
# Usage:
#   ./build-ez.sh <rabbit_common dir>        use a local plugins/rabbit_common-<vsn>
#   ./build-ez.sh --rmq-release <version>    download the generic-unix release and use its rabbit_common
# Output: _build/<app>-<vsn>-otp<OTP>.ez     (named by the OTP major it was built on)
set -euo pipefail
APP=rabbitmq_auth_backend_aoptoken
VSN=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' src/${APP}.app.src)
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')

if [ "${1:-}" = "--rmq-release" ]; then
  V="${2:?need a RabbitMQ version, e.g. 3.13.7}"
  T="_build/rmq-${V}"
  mkdir -p "${T}"
  URL="https://github.com/rabbitmq/rabbitmq-server/releases/download/v${V}/rabbitmq-server-generic-unix-${V}.tar.xz"
  echo ">> downloading ${URL}"
  curl -fsSL "${URL}" | tar -xJ -C "${T}"
  RCDIR="$(ls -d ${T}/rabbitmq_server-*/plugins/rabbit_common-*)"
else
  RCDIR="${1:?usage: build-ez.sh <rabbit_common dir> | --rmq-release <version>}"
fi

INCROOT="$(dirname "${RCDIR}")"
if [ "$(basename "${RCDIR}")" != "rabbit_common" ]; then
  INCROOT="_build/incroot"; rm -rf "${INCROOT}"; mkdir -p "${INCROOT}"
  ln -s "$(cd "${RCDIR}" && pwd)" "${INCROOT}/rabbit_common"
fi
echo ">> OTP ${OTP}; rabbit_common: ${RCDIR}"

OUT="_build/${APP}-${VSN}"
rm -rf "${OUT}"; mkdir -p "${OUT}/ebin"
erlc -I "${INCROOT}" -pa "${RCDIR}/ebin" -o "${OUT}/ebin" src/rabbit_auth_backend_aoptoken.erl
sed 's/{modules, \[\]}/{modules, [rabbit_auth_backend_aoptoken]}/' \
    src/${APP}.app.src > "${OUT}/ebin/${APP}.app"
EZ="${APP}-${VSN}-otp${OTP}.ez"
( cd _build && rm -f "${EZ}" && zip -qr "${EZ}" "${APP}-${VSN}" )
echo ">> built: _build/${EZ}"

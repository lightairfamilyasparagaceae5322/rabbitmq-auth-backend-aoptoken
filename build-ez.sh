#!/bin/bash
# Build an installable .ez plugin package.
#   ./build-ez.sh <rabbit_common dir>
#   ./build-ez.sh --rmq-release <version>
# Output: _build/<app>-<vsn>-otp<OTP>.ez  (named by the OTP major it was built on)
set -euo pipefail
APP=rabbitmq_auth_backend_aoptoken
VSN=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' src/${APP}.app.src)
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')
RCDIR=$(scripts/rabbit-common.sh "$@")

INCROOT="_build/incroot"; rm -rf "${INCROOT}"; mkdir -p "${INCROOT}"
ln -s "$(cd "${RCDIR}" && pwd)" "${INCROOT}/rabbit_common"
echo ">> OTP ${OTP}; rabbit_common: ${RCDIR}"

OUT="_build/${APP}-${VSN}"
rm -rf "${OUT}"; mkdir -p "${OUT}/ebin"
erlc -I "${INCROOT}" -pa "${RCDIR}/ebin" -o "${OUT}/ebin" src/rabbit_auth_backend_aoptoken.erl
sed 's/{modules, \[\]}/{modules, [rabbit_auth_backend_aoptoken]}/' \
    src/${APP}.app.src > "${OUT}/ebin/${APP}.app"
EZ="${APP}-${VSN}-otp${OTP}.ez"
( cd _build && rm -f "${EZ}" && zip -qr "${EZ}" "${APP}-${VSN}" )
echo ">> built: _build/${EZ}"

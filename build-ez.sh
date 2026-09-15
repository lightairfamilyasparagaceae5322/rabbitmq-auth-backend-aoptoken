#!/bin/bash
# Build an installable .ez plugin package.
# Usage:
#   ./build-ez.sh <rabbit_common dir>     use a local RabbitMQ plugins/rabbit_common-<vsn>
#   ./build-ez.sh --download <git-ref>    fetch rabbit_common headers from rabbitmq-server@<ref>
# Output: _build/<app>-<vsn>-otp<OTP>.ez  (named by the OTP major it was built on)
set -euo pipefail
APP=rabbitmq_auth_backend_aoptoken
VSN=$(sed -n 's/.*{vsn, *"\([^"]*\)".*/\1/p' src/${APP}.app.src)
OTP=$(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().')

if [ "${1:-}" = "--download" ]; then
  REF="${2:?need a git ref, e.g. v3.13.7}"
  RAW="https://raw.githubusercontent.com/rabbitmq/rabbitmq-server/${REF}/deps/rabbit_common"
  RC="_build/rc-${REF}"
  mkdir -p "${RC}/rabbit_common/include" "${RC}/rabbit_common/src"
  curl -fsSL "${RAW}/include/rabbit.hrl"              -o "${RC}/rabbit_common/include/rabbit.hrl"
  curl -fsSL "${RAW}/src/rabbit_authn_backend.erl"    -o "${RC}/rabbit_common/src/rabbit_authn_backend.erl"
  erlc -o "${RC}/rabbit_common/ebin" "${RC}/rabbit_common/src/rabbit_authn_backend.erl" 2>/dev/null || true
  INCROOT="${RC}"; EBIN="${RC}/rabbit_common/ebin"
else
  RCDIR="${1:?usage: build-ez.sh <rabbit_common dir> | --download <ref>}"
  INCROOT="$(dirname "${RCDIR}")"; EBIN="${RCDIR}/ebin"
  # normalize so include_lib("rabbit_common/include/...") resolves
  case "$(basename "${RCDIR}")" in
    rabbit_common) : ;;
    *) INCROOT="_build/incroot"; rm -rf "${INCROOT}"; mkdir -p "${INCROOT}"; ln -s "${RCDIR}" "${INCROOT}/rabbit_common" ;;
  esac
fi
echo ">> OTP ${OTP}; headers via ${1}"

OUT="_build/${APP}-${VSN}"
rm -rf "${OUT}"; mkdir -p "${OUT}/ebin"
erlc -I "${INCROOT}" -pa "${EBIN}" -o "${OUT}/ebin" src/rabbit_auth_backend_aoptoken.erl
sed 's/{modules, \[\]}/{modules, [rabbit_auth_backend_aoptoken]}/' \
    src/${APP}.app.src > "${OUT}/ebin/${APP}.app"
EZ="${APP}-${VSN}-otp${OTP}.ez"
( cd _build && rm -f "${EZ}" && zip -qr "${EZ}" "${APP}-${VSN}" )
echo ">> built: _build/${EZ}"

#!/bin/bash
# Compile and run the EUnit suite.
#   ./run-tests.sh <rabbit_common dir>
#   ./run-tests.sh --rmq-release <version>
set -euo pipefail
RCDIR=$(scripts/rabbit-common.sh "$@")
INCROOT="_build/incroot"; rm -rf "${INCROOT}"; mkdir -p "${INCROOT}"
ln -s "$(cd "${RCDIR}" && pwd)" "${INCROOT}/rabbit_common"
OUT=_build/test; rm -rf "${OUT}"; mkdir -p "${OUT}"
echo ">> OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().'); rabbit_common: ${RCDIR}"
erlc -I "${INCROOT}" -pa "${RCDIR}/ebin" -o "${OUT}" +debug_info src/rabbit_auth_backend_aoptoken.erl
erlc -I "${INCROOT}" -pa "${RCDIR}/ebin" -pa "${OUT}" -o "${OUT}" test/rabbit_auth_backend_aoptoken_tests.erl
# rabbit_json delegates to thoas, which ships alongside rabbit_common
PLUGINS_DIR="$(dirname "${RCDIR}")"
EXTRA_PA=""
for d in "${PLUGINS_DIR}"/thoas-*/ebin; do [ -d "$d" ] && EXTRA_PA="${EXTRA_PA} -pa $d"; done

erl -noshell -pa "${OUT}" -pa "${RCDIR}/ebin" ${EXTRA_PA} \
    -eval 'case eunit:test(rabbit_auth_backend_aoptoken_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

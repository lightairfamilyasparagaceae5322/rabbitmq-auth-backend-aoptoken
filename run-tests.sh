#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 martinx
# SPDX-License-Identifier: MPL-2.0
#
# Compile and run the EUnit suite.
#   ./run-tests.sh <rabbit_common dir>
#   ./run-tests.sh --rmq-release <version>
set -euo pipefail
RCDIR=$(scripts/rabbit-common.sh "$@")
# rabbit_authn_backend lives in rabbit_common up to RabbitMQ 4.1 and in rabbit
# from 4.2; put both on the code path so the compiler can check the behaviour.
RABBIT_PA=""
for d in "$(dirname "${RCDIR}")"/rabbit-[0-9]*/ebin; do [ -d "$d" ] && RABBIT_PA="-pa $d"; done
INCROOT="_build/incroot"; rm -rf "${INCROOT}"; mkdir -p "${INCROOT}"
ln -s "$(cd "${RCDIR}" && pwd)" "${INCROOT}/rabbit_common"
OUT=_build/test; rm -rf "${OUT}"; mkdir -p "${OUT}"
echo ">> OTP $(erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().'); rabbit_common: ${RCDIR}"
erlc -I "${INCROOT}" -pa "${RCDIR}/ebin" ${RABBIT_PA} -o "${OUT}" +debug_info src/rabbit_auth_backend_aoptoken.erl
erlc -I "${INCROOT}" -pa "${RCDIR}/ebin" -pa "${OUT}" -o "${OUT}" test/rabbit_auth_backend_aoptoken_tests.erl
# rabbit_json delegates to thoas, which ships alongside rabbit_common
PLUGINS_DIR="$(dirname "${RCDIR}")"
EXTRA_PA=""
for d in "${PLUGINS_DIR}"/thoas-*/ebin; do [ -d "$d" ] && EXTRA_PA="${EXTRA_PA} -pa $d"; done

erl -noshell -pa "${OUT}" -pa "${RCDIR}/ebin" ${EXTRA_PA} \
    -eval 'case eunit:test(rabbit_auth_backend_aoptoken_tests, [verbose]) of ok -> halt(0); _ -> halt(1) end.'

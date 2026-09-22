# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2026 martinx
# SPDX-License-Identifier: MPL-2.0
#
# Build as a RabbitMQ plugin against a specific broker version.
# Requires the RabbitMQ erlang.mk toolchain (https://www.rabbitmq.com/plugin-development.html).
PROJECT = rabbitmq_auth_backend_aoptoken
PROJECT_DESCRIPTION = Auth backend for pre-issued HS256 JWT (token:) credentials
DEPS = rabbit_common rabbit
DEP_PLUGINS = rabbitmq_build
include rabbitmq-components.mk
include erlang.mk

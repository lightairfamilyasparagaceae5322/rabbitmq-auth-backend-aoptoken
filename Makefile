# Build as a RabbitMQ plugin against a specific broker version.
# Requires the RabbitMQ erlang.mk toolchain (https://www.rabbitmq.com/plugin-development.html).
PROJECT = rabbitmq_auth_backend_aoptoken
PROJECT_DESCRIPTION = Auth backend for pre-issued HS256 JWT (token:) credentials
DEPS = rabbit_common rabbit
DEP_PLUGINS = rabbitmq_build
include rabbitmq-components.mk
include erlang.mk

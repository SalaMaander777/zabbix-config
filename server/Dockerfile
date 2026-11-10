# Расширенный образ сервера: добавляем python3 для внешних скриптов
# (в базовом образе zabbix-server-pgsql Python отсутствует - проверить: docker run --rm --entrypoint python3 ...).
ARG ZBX_VERSION
FROM --platform=linux/amd64 zabbix/zabbix-server-pgsql:alpine-${ZBX_VERSION}
USER root
RUN apk add --no-cache python3
USER 1997

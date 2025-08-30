#!/bin/sh
set -e # Выходить немедленно, если команда завершается с ошибкой.

# Скрипт-обертка для ожидания доступности сети перед запуском основного приложения.
# Шаг 1: Ожидает, пока контейнер сможет разрешать внешние DNS-имена (проверка внутренней сети).
# Шаг 2: Ожидает, пока DNS-запись самого бота станет видна (проверка внешней DNS-пропагации).

WAIT_TIMEOUT=100 # 100 секунд - максимальное время ожидания.

wait_for_dns() {
    local target_host="$1"
    echo "Entrypoint: Waiting for DNS resolution for '${target_host}'..."
    local start_time
    start_time=$(date +%s)
    # Используем `+nodnssec`, чтобы избежать ошибок SERVFAIL с DuckDNS
    while ! host +nodnssec "${target_host}" > /dev/null 2>&1; do
        local current_time
        current_time=$(date +%s)
        local elapsed_time
        elapsed_time=$((current_time - start_time))

        if [ ${elapsed_time} -ge ${WAIT_TIMEOUT} ]; then
            echo "Entrypoint: Timeout! Host '${target_host}' not resolvable after ${WAIT_TIMEOUT} seconds."
            exit 1
        fi

        echo "Entrypoint: Host '${target_host}' not yet resolvable, retrying in 5 seconds..."
        sleep 5
    fi
    echo "Entrypoint: Host '${target_host}' is resolvable."
}

# Шаг 1: Проверка базовой сетевой связности
wait_for_dns "api.telegram.org"

# Шаг 2: Ожидание распространения DNS-записи нашего вебхука
# WEBHOOK_HOST берется из .env файла, например: https://my-bot.example.com
if [ -n "${WEBHOOK_HOST}" ]; then
    webhook_hostname=$(echo "${WEBHOOK_HOST}" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
    wait_for_dns "${webhook_hostname}"
fi

echo "Entrypoint: All checks passed. Starting application..."
# `exec "$@"` заменяет текущий процесс (скрипт) на команду, переданную в аргументах (CMD из Dockerfile).
# Это позволяет приложению (python bot.py) корректно получать сигналы от Docker.
exec "$@"
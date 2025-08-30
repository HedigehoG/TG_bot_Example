#!/bin/sh
set -e # Выходить немедленно, если команда завершается с ошибкой.

# Скрипт-обертка для ожидания доступности сети перед запуском основного приложения.
# Шаг 1: Ожидает, пока контейнер сможет разрешать внешние DNS-имена (проверка внутренней сети).
# Шаг 2: Ожидает, пока DNS-запись самого бота станет видна через публичный DNS-сервер (проверка внешней DNS-пропагации).

INTERNAL_TARGET="api.telegram.org"
PUBLIC_DNS="8.8.8.8" # Google's Public DNS
WAIT_TIMEOUT=300 # 5 минут - максимальное время ожидания для каждого шага.

# --- Шаг 1: Ожидание готовности внутренней сети ---
echo "Entrypoint: Waiting for internal network to be ready (checking '${INTERNAL_TARGET}')..."
start_time=$(date +%s)
while ! host "${INTERNAL_TARGET}" > /dev/null 2>&1; do
    current_time=$(date +%s)
    elapsed_time=$((current_time - start_time))

    if [ ${elapsed_time} -ge ${WAIT_TIMEOUT} ]; then
        echo "Entrypoint: Timeout! Internal network not ready after ${WAIT_TIMEOUT} seconds."
        echo "--- Diagnostic Info ---"
        host "${INTERNAL_TARGET}" || true
        echo "-----------------------"
        exit 1
    fi

    echo "Entrypoint: Internal network not ready, retrying in 2 seconds..."
    sleep 2
done
echo "Entrypoint: Internal network is ready."

# --- Шаг 2: Ожидание распространения внешней DNS-записи ---
# WEBHOOK_HOST берется из .env файла, например: https://my-bot.example.com
if [ -n "${WEBHOOK_HOST}" ]; then
    EXTERNAL_TARGET_HOST=$(echo "${WEBHOOK_HOST}" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')

    # --- Шаг 2a: Проверка доступности публичного DNS ---
    echo "Entrypoint: Verifying connectivity to public DNS server ${PUBLIC_DNS}..."
    if ! host +nodnssec "google.com" "${PUBLIC_DNS}" > /dev/null 2>&1; then
        echo "Entrypoint: CRITICAL - Cannot resolve 'google.com' via ${PUBLIC_DNS}. There might be a network issue blocking access to the public DNS server."
        exit 1
    fi
    echo "Entrypoint: Public DNS server is reachable."

    # --- Шаг 2b: Ожидание распространения внешней DNS-записи ---
    echo "Entrypoint: Waiting for external DNS propagation for '${EXTERNAL_TARGET_HOST}' (checking via ${PUBLIC_DNS})..."
    start_time=$(date +%s)
    # Используем `+nodnssec`, чтобы избежать ошибок SERVFAIL с DuckDNS
    while ! host +nodnssec "${EXTERNAL_TARGET_HOST}" "${PUBLIC_DNS}" > /dev/null 2>&1; do
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))
 
        if [ ${elapsed_time} -ge ${WAIT_TIMEOUT} ]; then
            echo "Entrypoint: Timeout! External DNS for '${EXTERNAL_TARGET_HOST}' not ready after ${WAIT_TIMEOUT} seconds."
            exit 1
        fi
 
        echo "Entrypoint: Host '${EXTERNAL_TARGET_HOST}' not yet resolvable via public DNS, retrying in 5 seconds..."
        sleep 5
    done
    echo "Entrypoint: External DNS for '${EXTERNAL_TARGET_HOST}' has propagated."
fi

echo "Entrypoint: All checks passed. Starting application..."
# `exec "$@"` заменяет текущий процесс (скрипт) на команду, переданную в аргументах (CMD из Dockerfile).
# Это позволяет приложению (python bot.py) корректно получать сигналы от Docker.
exec "$@"
#!/bin/sh
set -e # Выходить немедленно, если команда завершается с ошибкой.

#
# Скрипт-обертка для ожидания доступности сети перед запуском основного приложения.
#

# Хост, который мы будем проверять. api.telegram.org - идеальный кандидат.
TARGET_HOST="api.telegram.org"
WAIT_TIMEOUT=60 # Максимальное время ожидания в секундах.

echo "Entrypoint: Waiting for network to be ready..."

# Perform an initial check to see if we need to wait at all.
if host "${TARGET_HOST}" > /dev/null 2>&1; then
    echo "Entrypoint: Network is ready on the first attempt."
else
    echo "Entrypoint: Initial network check failed. Will start retrying..."
    # Выводим диагностическую информацию при первой ошибке
    echo "--- Diagnostic Info (first failure) ---"
    host "${TARGET_HOST}" || true # Запускаем снова, чтобы увидеть ошибку. `|| true` предотвращает выход из-за `set -e`.
    echo "---------------------------------------"

    start_time=$(date +%s)
    while ! host "${TARGET_HOST}" > /dev/null 2>&1; do
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))

        if [ ${elapsed_time} -ge ${WAIT_TIMEOUT} ]; then
            echo "Entrypoint: Timeout! Network not ready after ${WAIT_TIMEOUT} seconds."
            exit 1
        fi

        echo "Entrypoint: Host ${TARGET_HOST} not yet resolvable, retrying in 2 seconds..."
        sleep 2
    done
fi

echo "Entrypoint: Network is ready. Starting application..."
# `exec "$@"` заменяет текущий процесс (скрипт) на команду, переданную в аргументах (CMD из Dockerfile).
# Это позволяет приложению (python bot.py) корректно получать сигналы от Docker.
exec "$@"
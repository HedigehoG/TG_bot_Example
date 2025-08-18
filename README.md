# tg-webhook-bot (Python + aiogram)

Это готовый шаблон для Telegram-бота на **Python**, **aiogram** и **aiohttp**. Он работает через вебхуки и оптимизирован для простого и безопасного развертывания на сервере с помощью Docker и GitHub Actions.

### Стек
- **Бот**: Python + aiogram + aiohttp
- **Деплой**: Docker + Docker Compose + GitHub Actions
- **Веб-сервер (рекомендуется)**: Caddy для автоматического HTTPS

### Локальная разработка

1.  Скопируйте `.env.example` в новый файл `.env`.
2.  Укажите в нем `BOT_TOKEN`, `WEBHOOK_HOST` и `PORT`.
3.  Запустите локально для проверки через Docker:

```bash
docker-compose up --build -d
```

### Настройка Caddy на сервере

Для маршрутизации запросов к ботам мы будем использовать поддомены (например, `my-bot.your-domain.com`). Это более чистый и гибкий подход, чем маршрутизация по URL.

**Что нужно сделать:**
1.  **Настроить DNS:** У вашего регистратора доменов создайте `A`-запись для каждого бота, которая будет указывать на IP-адрес вашего сервера.
    - `my-first-bot.your-domain.com` -> `SERVER_IP`
    # tg-webhook-bot (Python + aiogram)

    Коротко: шаблон Telegram-бота на Python с поддержкой вебхуков, готовый к запуску в Docker и к деплою через GitHub Actions + простая интеграция с Caddy для HTTPS.

    ## Что внутри
    - Код бота: `bot.py` (aiohttp + aiogram)
    - Docker + `docker-compose.yml` для локального запуска
    - Скрипты и примеры для продакшен-деплоя в каталоге `deploy/` (`bootstrap-server-custom.sh`, `Caddyfile.example`, `docker-compose.prod.yml` генерируется скриптом)

    ## Быстрый старт (локально)
    1. Скопируйте (если есть) `.env.example` в `.env` и заполните переменные: `BOT_TOKEN`, `WEBHOOK_HOST`, `PORT`.
    2. Соберите и запустите контейнеры:

    ```powershell
    docker-compose up --build
    ```

    3. Проверьте логи контейнера, чтобы убедиться, что бот инициализировался и вебхук установлен.

    Если хотите тестировать без внешнего хоста, можно использовать ngrok/LocalTunnel и указать публичный URL в `WEBHOOK_HOST`.

    ## Требования
    - Docker и Docker Compose (локально для теста)
    - Python 3.11 в Docker-образе (поставляется в Dockerfile)

    ## Запуск и отладка
    - Локально: `docker-compose up --build`.
    - Просмотр логов: `docker-compose logs -f`.
    - Быстрая проверка: отправьте сообщение боту в Telegram — в логах контейнера должны появиться обработчики.

    ## Деплой на сервер (кратко)
    Репозиторий содержит автоматизированный bootstrap-скрипт `deploy/bootstrap-server-custom.sh`, который:

    - устанавливает Docker и Docker Compose на сервере;
    - создает пользователя для деплоя;
    - подготавливает структуру `/opt/pybot/<BOT_NAME>` и bare-репозиторий для git-пушей;
    - генерирует `docker-compose.prod.yml`, который ссылается на образ в GHCR (`ghcr.io/<OWNER>/tg-webhook-bot:latest`).

    Пример запуска скрипта (на сервере):

    ```powershell
    sudo OWNER=your-github-username BOOT_USER=deploy BOT_NAME=my_first_bot BOT_PORT=8001 ./deploy/bootstrap-server-custom.sh
    ```

    После этого скрипт выведет инструкцию по добавлению `git remote` и отправке кода на сервер.

    > Важно: отредактируйте `/opt/pybot/<BOT_NAME>/.env` на сервере и вставьте настоящий `BOT_TOKEN` и другие секреты.

    ## Caddy и HTTPS
    Рекомендуемый способ для обеспечения HTTPS — Caddy, который автоматически получает сертификаты и проксирует поддомены на нужные порты. В `deploy/Caddyfile.example` есть пример конфигурации; скопируйте и адаптируйте его в `/etc/caddy/Caddyfile` на сервере.

    Короткие шаги:
    1. Настройте DNS A-запись для каждого поддомена на IP сервера.
    2. Используйте `deploy/Caddyfile.example` как шаблон.
    3. Перезагрузите Caddy: `sudo systemctl reload caddy`.

    ## CI/CD (GitHub Actions)
    Ожидаемый процесс:

    1. GitHub Actions собирает Docker-образ и публикует его в GHCR.
    2. После успешной публикации workflow по SSH подключается к серверу и выполняет `docker-compose pull && docker-compose up -d` в рабочей директории.

    Необходимые secrets в GitHub:
    - `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `WORK_DIR` (и, при необходимости, `GHCR_TOKEN` для публикации образа).

    ## Структура директорий (локально / на сервере)

    Локально (репозиторий):

    ```
    bot.py
    Dockerfile
    docker-compose.yml
    deploy/
        ├─ bootstrap-server-custom.sh
        ├─ Caddyfile.example
        └─ docker-compose.prod.yml (пример)
    ```

    На сервере (пример):

    ```
    /opt/pybot/
    ├── conf_git/
    │   └── <bot>_repo.git  # bare-репозиторий для деплоя
    └── <bot>/
            ├── .env
            ├── bot.py
            └── docker-compose.prod.yml
    ```

    ## Troubleshooting
    - Бот не стартует — проверьте логи `docker-compose logs` и `.env`.
    - Вебхук не устанавливается — проверьте `WEBHOOK_HOST`, доступность порта и Caddy (если используется).
    - Ошибки деплоя через GitHub Actions — проверьте, что образ публикуется в том же репозитории GHCR, который указан в `docker-compose.prod.yml`.

    ## Полезные файлы
    - `deploy/bootstrap-server-custom.sh` — автоматическая установка и подготовка сервера
    - `deploy/Caddyfile.example` — шаблон конфигурации Caddy
    - `docker-compose.yml` — локальный compose

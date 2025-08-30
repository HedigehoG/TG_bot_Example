#!/bin/bash
#
# Скрипт для первоначальной настройки сервера для деплоя Telegram-бота.
#
# Что делает скрипт:
# 1. Проверяет права суперпользователя (root).
# 2. Устанавливает Docker и Docker Compose, если они отсутствуют.
# 3. Создает специального пользователя для деплоя.
# 4. Настраивает SSH-доступ по ключу для этого пользователя, отключая вход по паролю.
# 5. Генерирует SSH-ключ для деплоя и выводит данные для настройки GitHub Actions Secrets.
# 6. Создает базовые конфигурационные файлы `.env` и `docker-compose.yml`.
#

set -euo pipefail

# --- Глобальные переменные и значения по умолчанию ---
BOT_NAME_DEFAULT="bot_main"
WEBHOOK_HOST_URL=${WEBHOOK_HOST_URL:-}
HOST_PORT_DEFAULT=8001
CONTAINER_PORT=8080 # Внутренний порт приложения, должен совпадать с тем, что в Dockerfile
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-} # Пример: my-username/my-cool-repo

# Переменные, которые будут определены интерактивно
BOT_NAME=${BOT_NAME:-}
DEPLOY_USER=${DEPLOY_USER:-}
WORK_DIR="" # Определяется на основе DEPLOY_USER
HOST_PORT=${HOST_PORT:-}
CLEANUP_COMMAND_VAR=""
DEPLOY_KEY_PATH=""


check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Ошибка: Этот скрипт должен выполняться с правами root. Пожалуйста, используйте sudo." >&2
    exit 1
  fi
}

check_dependencies() {
    echo "Проверка системных зависимостей..."
    local missing_packages=()
    # sudo необходимо для создания sudoers файла для скрипта очистки
    if ! command -v sudo >/dev/null 2>&1; then
        missing_packages+=("sudo")
    fi
    # curl используется для загрузки скриптов и ключей
    if ! command -v curl >/dev/null 2>&1; then
        missing_packages+=("curl")
    fi
    # host (из dnsutils) используется для проверки DNS
    if ! command -v host >/dev/null 2>&1; then
        missing_packages+=("dnsutils")
    fi
    # gpg используется для установки ключа Docker-репозитория
    if ! command -v gpg >/dev/null 2>&1; then
        missing_packages+=("gnupg")
    fi

    if [ ${#missing_packages[@]} -gt 0 ]; then
        echo "Обнаружены отсутствующие пакеты: ${missing_packages[*]}"
        echo "Запускаем apt-get update..."
        apt-get -qq update
        echo "Установка пакетов..."
        apt-get -qq install -y "${missing_packages[@]}"
        echo "Зависимости установлены."
    fi
}

 _get_server_public_ip() {
  # Пытаемся получить публичный IPv4 с таймаутом. Если не вышло, ищем первый IPv4 в выводе hostname -I.
  curl -4s --max-time 5 ifconfig.me || hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

validate_input() {
  if [ -z "${GITHUB_REPOSITORY}" ] || [[ ! "${GITHUB_REPOSITORY}" == */* ]]; then
    echo "Ошибка: Переменная GITHUB_REPOSITORY не задана или имеет неверный формат." >&2
    echo "Пожалуйста, укажите ее в формате 'имя-пользователя/имя-репозитория'." >&2
    echo "Пример: sudo GITHUB_REPOSITORY=your-username/your-repo-name ${0}" >&2
    exit 1
  fi
}

validate_webhook_url() {
    local url_to_validate="$1"
    local server_ip="$2"

    if [ -z "${url_to_validate}" ]; then
      echo "URL не может быть пустым." >&2
      return 1
    fi

    # Извлекаем хост из URL (убираем протокол, путь и порт)
    local hostname
    hostname=$(echo "${url_to_validate}" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')
    if [ -z "${hostname}" ]; then
        echo "Не удалось извлечь имя хоста из URL '${url_to_validate}'. Пожалуйста, введите корректный URL (например, https://domain.com)." >&2
        return 1
    fi

    echo "Проверка DNS для хоста '${hostname}'..."
    local resolved_ip
    resolved_ip=$(host -t A "${hostname}" | awk '/has address/ {print $4; exit}')

    if [ -z "${resolved_ip}" ]; then
      echo "Ошибка: не удалось разрешить доменное имя '${hostname}' в IP-адрес." >&2
      echo "Убедитесь, что для этого домена настроена A-запись в вашей DNS-зоне и она успела обновиться." >&2
      return 1
    fi

    echo "Домен '${hostname}' успешно разрешен в IP-адрес: ${resolved_ip}"

    if [ -n "${server_ip}" ] && [ "${resolved_ip}" != "${server_ip}" ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: IP-адрес домена (${resolved_ip}) НЕ совпадает с IP-адресом этого сервера (${server_ip})." >&2
        echo "Это нормально, если вы используете прокси (например, Cloudflare), но может быть ошибкой." >&2
        # Если скрипт запущен неинтерактивно (stdin не терминал), то просто продолжаем с предупреждением.
        # Если интерактивно - спрашиваем подтверждение.
        if [ -t 0 ]; then
            read -p "Вы уверены, что хотите использовать этот URL? (y/N): " choice
            [[ "${choice}" =~ ^[Yy]$ ]] || return 1
        fi
    elif [ -n "${server_ip}" ]; then # Подразумевается, что resolved_ip == server_ip
        echo "Отлично! IP-адрес домена совпадает с IP-адресом сервера."
    fi
    return 0 # Успешная валидация
}

gather_interactive_inputs() {
  echo
  echo "--- Настройка конфигурации ---"

  if [ -z "${BOT_NAME}" ]; then
    local bot_name_input
    read -p "Введите имя для вашего бота [${BOT_NAME_DEFAULT}]: " bot_name_input
    BOT_NAME=${bot_name_input:-${BOT_NAME_DEFAULT}}
  else
    echo "Используется имя бота из переменной окружения: ${BOT_NAME}"
  fi

  if [ -z "${DEPLOY_USER}" ]; then
    local deploy_user_input
    read -p "Введите имя пользователя для деплоя (будет создан на сервере) [${BOT_NAME}]: " deploy_user_input
    DEPLOY_USER=${deploy_user_input:-${BOT_NAME}}
  else
    echo "Используется пользователь для деплоя из переменной окружения: ${DEPLOY_USER}"
  fi

  # Определяем рабочую директорию на основе имени пользователя.
  # Это должно быть сделано здесь, так как WORK_DIR зависит от DEPLOY_USER.
  WORK_DIR="/home/${DEPLOY_USER}"

  local server_ip
  server_ip=$(_get_server_public_ip)
  if [ -z "${server_ip}" ]; then
      echo "Предупреждение: не удалось определить публичный IP-адрес сервера. Проверка домена будет неполной." >&2
  else
      echo "Обнаружен публичный IP сервера: ${server_ip}"
  fi

  if [ -n "${WEBHOOK_HOST_URL}" ]; then
    echo "Используется URL вебхука из переменной окружения: ${WEBHOOK_HOST_URL}"
    if ! validate_webhook_url "${WEBHOOK_HOST_URL}" "${server_ip}"; then
      echo "Ошибка: URL вебхука из переменной окружения не прошел валидацию." >&2
      exit 1
    fi
  else
    local webhook_input=""
    while true; do
      read -p "Введите публичный URL для вебхука (например, https://my-bot.example.com): " webhook_input
      if validate_webhook_url "${webhook_input}" "${server_ip}"; then
        WEBHOOK_HOST_URL=${webhook_input}
        break
      fi
      echo "Пожалуйста, попробуйте снова." >&2
    done
  fi

  if [ -z "${HOST_PORT}" ]; then
    local host_port_input
    read -p "Введите внешний порт для бота (на хосте) [${HOST_PORT_DEFAULT}]: " host_port_input
    HOST_PORT=${host_port_input:-${HOST_PORT_DEFAULT}}
  else
    echo "Используется порт хоста из переменной окружения: ${HOST_PORT}"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    echo "Docker уже установлен. Пропускаем установку."
    return
  fi

  echo "Установка Docker..."
  # Зависимости curl и gnupg устанавливаются централизованно в check_dependencies
  apt-get -qq update
  apt-get -qq install -y ca-certificates lsb-release

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # Примечание: Скрипт адаптирован для Ubuntu. Для других Debian-based систем 'ubuntu' может потребоваться заменить на 'debian'.
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list

  apt-get -qq update
  apt-get -qq install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
  echo "Docker успешно установлен и запущен."
}

setup_deploy_user() {
  if id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    echo "Пользователь ${DEPLOY_USER} уже существует. Пропускаем создание."
    return
  fi

  echo "Создание пользователя для деплоя: ${DEPLOY_USER}..."
  # Флаг -m создает домашнюю директорию, которая и будет нашей WORK_DIR.
  useradd -m -s /bin/bash -d "${WORK_DIR}" "${DEPLOY_USER}"
  usermod -aG docker "${DEPLOY_USER}"
  echo "Пользователь ${DEPLOY_USER} создан и добавлен в группу docker."

  # Настройка SSH для входа по ключу
  local ssh_dir="${WORK_DIR}/.ssh"
  install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${ssh_dir}"
  touch "${ssh_dir}/authorized_keys"
  chmod 600 "${ssh_dir}/authorized_keys"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "${ssh_dir}/authorized_keys"
  echo "Создана директория SSH для пользователя ${DEPLOY_USER}."

  # Настраиваем SSH-сервер для безопасного доступа, отключая вход по паролю.
  # Мы используем drop-in файл конфигурации, чтобы не изменять основной sshd_config.
  # Это более безопасный и современный подход, который не затрагивает системные файлы.
  echo "Настройка SSH сервера для безопасного доступа (отключение входа по паролю)..."
  local ssh_custom_config="/etc/ssh/sshd_config.d/99-disable-password-auth.conf"
  mkdir -p /etc/ssh/sshd_config.d
  echo "PasswordAuthentication no" > "${ssh_custom_config}"
  echo "PubkeyAuthentication yes" >> "${ssh_custom_config}"
  systemctl restart sshd
  echo "SSH сервер перенастроен: вход по паролю отключен, вход по ключу разрешен."

  # Генерация и настройка ключа для деплоя
  echo "Генерация ключа для деплоя (формат PEM для GitHub Actions)..."
  local deploy_key_path="${ssh_dir}/id_ed25519_deploy"
  DEPLOY_KEY_PATH="${deploy_key_path}" # Сохраняем путь в глобальную переменную для print_summary
  ssh-keygen -m PEM -t ed25519 -f "${deploy_key_path}" -N "" -C "deploy-key-${BOT_NAME}@$(hostname)"

  cat "${deploy_key_path}.pub" >> "${ssh_dir}/authorized_keys"
  chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${ssh_dir}"
  echo "Ключ для деплоя сгенерирован и добавлен в authorized_keys."
}

setup_cleanup_script() {
  echo "Настройка скрипта для удаления..."
  # Так как bootstrap-скрипт запускается через curl, он не может найти локальные файлы.
  # Мы загружаем скрипт очистки напрямую из GitHub репозитория.
  local cleanup_script_url="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/main/deploy/cleanup-server.sh"
  local cleanup_script_dest_path="${WORK_DIR}/cleanup-server.sh"

  echo "Загрузка скрипта очистки с ${cleanup_script_url}..."
  if ! curl -fsSL "${cleanup_script_url}" -o "${cleanup_script_dest_path}"; then
    echo "Ошибка: Не удалось загрузить скрипт очистки 'cleanup-server.sh'." >&2
    echo "Убедитесь, что репозиторий ${GITHUB_REPOSITORY} публичный и содержит этот файл в ветке 'main'." >&2
    exit 1
  fi

  chmod +x "${cleanup_script_dest_path}"
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "${cleanup_script_dest_path}"

  # Настройка sudo для безопасного запуска скрипта очистки из GitHub Actions
  # Убедимся, что директория для drop-in файлов sudo существует.
  mkdir -p /etc/sudoers.d
  local sudoers_file="/etc/sudoers.d/99-${DEPLOY_USER}-cleanup"
  echo "Предоставление прав на выполнение скрипта очистки через sudo..."
  echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD: ${cleanup_script_dest_path} ${DEPLOY_USER}" > "${sudoers_file}"
  chmod 0440 "${sudoers_file}"
  CLEANUP_COMMAND_VAR="sudo ${cleanup_script_dest_path} ${DEPLOY_USER}"
  echo "Скрипт очистки настроен и размещен в ${cleanup_script_dest_path}."
}

create_env_file() {
  local env_file="${WORK_DIR}/.env"
  if [ -f "${env_file}" ]; then
    echo ".env файл уже существует. Пропускаем создание."
    return
  fi

  echo "Создание .env файла в ${WORK_DIR}"

  # Генерируем безопасный секретный токен для вебхука, который соответствует требованиям Telegram
  # (A-Z, a-z, 0-9, _ and -). Мы используем base64 и удаляем неразрешенные символы.
  # Это решает проблему "secret token contains unallowed characters".
  local webhook_secret=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')

  cat > "${env_file}" <<ENV
# Этот файл содержит переменные окружения для вашего бота.

# Имя бота, используется для docker-compose (например, для имени контейнера).
BOT_NAME=${BOT_NAME}

# Публичный URL, на который Telegram будет отправлять обновления.
WEBHOOK_HOST=${WEBHOOK_HOST_URL}

# Секретный токен для верификации запросов от Telegram (заголовок X-Telegram-Bot-Api-Secret-Token).
# Кавычки вокруг значения — хорошая практика для .env файлов.
WEBHOOK_SECRET="${webhook_secret}"

# Порт на хост-машине, который будет пробрасываться в контейнер.
BOT_PORT=${HOST_PORT}

# Внутренний порт, на котором приложение слушает внутри контейнера.
# Это значение должно совпадать с переменной CONTAINER_PORT в docker-compose.yml.
LISTEN_PORT=${CONTAINER_PORT}

# BOT_TOKEN будет автоматически добавлен в конец этого файла во время деплоя из GitHub Secrets.
ENV
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "${env_file}"
  echo ".env файл создан."
}

create_docker_compose_file() {
  local compose_file="${WORK_DIR}/docker-compose.yml"
  if [ -f "${compose_file}" ]; then
    echo "docker-compose.yml файл уже существует. Пропускаем создание."
    return
  fi

  echo "Создание docker-compose.yml в ${WORK_DIR}"
  # Приводим имя репозитория к нижнему регистру, как это делает ghcr.io
  local bot_image="ghcr.io/${GITHUB_REPOSITORY,,}:latest"

  # Важно: \${VAR} используется для того, чтобы переменные окружения
  # (BOT_IMAGE, BOT_PORT) были подставлены утилитой docker-compose при запуске,
  # а не самим bash-скриптом при создании файла.
  cat > "${compose_file}" <<YML
services:
  bot:
    # Имя образа будет передаваться через переменную окружения BOT_IMAGE во время деплоя.
    # Явно задаем имя контейнера, чтобы оно было предсказуемым (например, 'bot_main'),
    # вместо автоматически сгенерированного. Значение берется из .env файла.
    container_name: \${BOT_NAME}
    # Здесь мы указываем значение по умолчанию для локальных запусков.
    image: \${BOT_IMAGE:-${bot_image}}
    env_file:
      - .env
    ports:
      # Проброс порта с хоста (переменная из .env) в контейнер (константа).
      - "\${BOT_PORT}:${CONTAINER_PORT}"
    restart: unless-stopped
    # Настройка ротации логов, чтобы они не занимали все место на диске.
    # Храним 3 файла логов по 10MB каждый.
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    # Ограничиваем ресурсы для защиты сервера от перегрузки.
    mem_limit: 150m
    memswap_limit: 300m
    healthcheck:
      # Проверяем, отвечает ли веб-сервер внутри контейнера.
      # ВАЖНО: для работы healthcheck в вашем Docker-образе должен быть установлен curl,
      # а само приложение должно отвечать на GET-запросы по пути /health.
      test: ["CMD", "curl", "-f", "http://localhost:${CONTAINER_PORT}/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      # Даем контейнеру 60 секунд на запуск, прежде чем healthcheck начнет считаться провальным.
      start_period: 60s
    # Явно указываем DNS-серверы для надежного разрешения имен внутри контейнера.
    # Это решает распространенную проблему "Temporary failure in name resolution".
    dns:
      - 8.8.8.8
      - 1.1.1.1 # Резервный DNS-сервер
    networks:
      - botnet

networks:
  botnet:
    driver: bridge
YML
  chown "${DEPLOY_USER}:${DEPLOY_USER}" "${compose_file}"
  echo "docker-compose.yml файл создан."
}

display_caddy_config() {
  # Извлекаем только хост из полного URL
  local hostname
  hostname=$(echo "${WEBHOOK_HOST_URL}" | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|:.*$||')

  echo
  echo "================== Пример конфигурации для реверс-прокси Caddy =================="
  echo "Если вы используете Caddy, добавьте этот блок в ваш Caddyfile"
  echo "(обычно /etc/caddy/Caddyfile) и перезапустите Caddy (systemctl reload caddy):"
  echo "--------------------------------------------------------------------------------"
  # Используем printf для форматирования, чтобы избежать проблем с отступами
  printf "\n%s {\n    reverse_proxy localhost:%s\n}\n\n" "${hostname}" "${HOST_PORT}"
  echo "--------------------------------------------------------------------------------"
  echo "Caddy автоматически получит и будет обновлять для вас SSL-сертификат."
  echo
}

display_github_secrets() {
  local deploy_key_path="$1"
  if [ -z "${deploy_key_path}" ]; then
    echo "Критическая ошибка: путь к ключу деплоя не был определен." >&2
    return
  fi

  local ssh_host
  ssh_host=$(_get_server_public_ip)

  echo
  echo "====================== Секреты для GitHub Actions ======================"
  echo "Добавьте следующие секреты в настройки вашего репозитория на GitHub:"
  echo "--------------------------------------------------------------------"
  echo "SSH_HOST: ${ssh_host}"
  echo "SSH_USER: ${DEPLOY_USER}"
  echo "CLEANUP_COMMAND: ${CLEANUP_COMMAND_VAR}"

  echo "---------------------- SSH_PRIVATE_KEY (КРИТИЧЕСКИ ВАЖНО!) ------------------"
  echo "Скопируйте всё, что находится между линиями ==, включая 'BEGIN' и 'END'."
  echo "ВАЖНО: Секрет в GitHub должен содержать пустую строку после 'END PRIVATE KEY'."
  echo "Скрипт выводит ее автоматически, просто убедитесь, что скопировали всё."
  echo "===================================================================="
  cat "${deploy_key_path}"
}

print_summary() {
  echo
  echo "===================================================================="
  echo "Первоначальная настройка сервера завершена!"
  echo "===================================================================="

  display_github_secrets "${DEPLOY_KEY_PATH}"

  echo
  echo "--- Следующие шаги ---"
  echo "1. Перейдите в настройки вашего репозитория на GitHub и добавьте секреты:"
  echo "   (Settings -> Secrets and variables -> Actions -> New repository secret)"
  echo "   - Добавьте все секреты, показанные выше (\`SSH_HOST\`, \`SSH_USER\`, \`CLEANUP_COMMAND\`, \`SSH_PRIVATE_KEY\`)."
  echo "   - Добавьте еще один, самый важный секрет: \`BOT_TOKEN\` (токен от @BotFather)."

  display_caddy_config

  echo "2. Проверьте и при необходимости отредактируйте файл ${WORK_DIR}/.env на сервере."
  echo "3. Отправьте изменения в ветку 'main' (или другую основную ветку), чтобы запустить деплой."
}

main() {
  check_root
  validate_input
  check_dependencies

  # Собираем все интерактивные данные от пользователя в самом начале
  gather_interactive_inputs

  echo "--- Запуск настройки сервера для бота: ${BOT_NAME} ---"
  echo "Пользователь для деплоя: ${DEPLOY_USER}"
  echo "Рабочая директория: ${WORK_DIR}"
  echo "--------------------------------------------------------"

  install_docker
  setup_deploy_user
  setup_cleanup_script
  create_env_file
  create_docker_compose_file
  print_summary
}

# --- Точка входа в скрипт ---
main "$@"

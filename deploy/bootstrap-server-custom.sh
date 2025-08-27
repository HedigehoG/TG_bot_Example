#!/bin/bash
# Скрипт для первоначальной настройки сервера для деплоя Telegram-бота.
# Устанавливает Docker, создает пользователя для деплоя и настраивает окружение.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

BOT_NAME=${BOT_NAME:-bot_main}
# Для лучшей изоляции и простоты назовем пользователя для деплоя так же, как и бота.
DEPLOY_USER=${BOT_NAME}
BOT_PORT=${BOT_PORT:-8001}
CONTAINER_PORT=${CONTAINER_PORT:-8080} 
GITHUB_REPOSITORY=${GITHUB_REPOSITORY:-} # e.g., my-username/my-cool-repo

if [ -z "${GITHUB_REPOSITORY}" ] || [[ ! "${GITHUB_REPOSITORY}" == */* ]]; then
  echo "Error: GitHub repository is not set or has an invalid format."
  echo "Please provide it via the GITHUB_REPOSITORY environment variable."
  echo "Usage: sudo GITHUB_REPOSITORY=your-username/your-repo-name ./bootstrap-server-custom.sh"
  exit 1
fi
# Convert to lowercase to match GitHub Actions behavior for ghcr.io images.
GITHUB_REPOSITORY=${GITHUB_REPOSITORY,,}

# Рабочей директорией будет домашний каталог пользователя.
WORK_DIR="/home/${DEPLOY_USER}"

echo "Запуск настройки: WORK_DIR=${WORK_DIR}, DEPLOY_USER=${DEPLOY_USER}, BOT_NAME=${BOT_NAME}"

# install docker (same as generic)
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  # Примечание: Скрипт адаптирован для Ubuntu. Для других Debian-based систем 'ubuntu' может потребоваться заменить на 'debian'.
  tee /etc/apt/sources.list.d/docker.list > /dev/null <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# create user if not exists
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "Пользователь ${DEPLOY_USER} не найден. Создание..."
  # Флаг -m создает домашнюю директорию, которая и будет нашей WORK_DIR.
  useradd -m -s /bin/bash -d "${WORK_DIR}" "${DEPLOY_USER}"
  # Add user to docker group to manage containers without sudo
  usermod -aG docker "${DEPLOY_USER}"
  echo "Пользователь ${DEPLOY_USER} создан и добавлен в группу docker."

  # Create .ssh directory and authorized_keys file
  SSH_DIR="/home/${DEPLOY_USER}/.ssh"
  mkdir -p "${SSH_DIR}"
  touch "${SSH_DIR}/authorized_keys"
  chmod 700 "${SSH_DIR}"
  chmod 600 "${SSH_DIR}/authorized_keys"
  chown -R ${DEPLOY_USER}:${DEPLOY_USER} "${SSH_DIR}"
  echo "Создана директория SSH для пользователя ${DEPLOY_USER}."

  # Ensure PubkeyAuthentication is enabled in sshd_config and restart sshd.
  # This is crucial for the deployment key to work.
  if grep -qE '^\s*#?\s*PubkeyAuthentication' /etc/ssh/sshd_config; then
    sed -i -E 's/^\s*#?\s*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  else
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
  fi
  if grep -qE '^\s*#?\s*PasswordAuthentication' /etc/ssh/sshd_config; then
    sed -i -E 's/^\s*#?\s*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  fi
  systemctl restart sshd
  echo "SSH server reconfigured to accept public key authentication."

  # --- Генерация ключей ---
  # 1. Генерируем ключ для деплоя в формате PEM для совместимости с GitHub Actions
  echo "Генерация ключа для деплоя (формат PEM для GitHub Actions)..."
  DEPLOY_KEY_PATH="${SSH_DIR}/id_ed25519_deploy"
  ssh-keygen -m PEM -t ed25519 -f "${DEPLOY_KEY_PATH}" -N "" -C "deploy-key-${BOT_NAME}@$(hostname)"
 
  # Добавляем публичный ключ в authorized_keys
  cat "${DEPLOY_KEY_PATH}.pub" >> "${SSH_DIR}/authorized_keys"

  chown -R ${DEPLOY_USER}:${DEPLOY_USER} "${SSH_DIR}"
  echo "Ключ для деплоя сгенерирован и авторизован."

  echo "====================== GitHub Actions Secrets ======================"
  echo "Add the following secrets to your GitHub repository settings:"
  echo "--------------------------------------------------------------------"
  # Пытаемся получить публичный IPv4. Если не вышло, ищем первый IPv4 в выводе hostname -I.
  echo "SSH_HOST: $(curl -4s ifconfig.me || hostname -I | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}')"
  echo "SSH_USER: ${DEPLOY_USER}"
  echo "---------------------- SSH_PRIVATE_KEY (ВАЖНО!) ------------------"
  echo "Скопируйте всё, что находится между линиями, включая 'BEGIN' и 'END' и пустую строку после ключа."
  echo "Этот ключ предназначен ТОЛЬКО для GitHub Actions."
  echo "" # Add a blank line for easier copying
  cat "${DEPLOY_KEY_PATH}"
  echo "" # Add a blank line for easier copying
  echo "===================================================================="
  # Securely remove the private key from the server after displaying it
  # We are commenting this line out to prevent issues with incorrectly copied keys.
  # The private key will remain in /home/${DEPLOY_USER}/.ssh/ for later retrieval if needed.
  # rm -f "${DEPLOY_KEY_PATH}"
fi

# sample env and compose
if [ ! -f "${WORK_DIR}/.env" ]; then
  cat > "${WORK_DIR}/.env" <<ENV
# BOT_TOKEN будет автоматически добавлен во время деплоя из GitHub Secrets.
# WEBHOOK_HOST должен указывать на публичный адрес вашего сервера, например https://my-first-bot.your-domain.com
WEBHOOK_HOST=https://${BOT_NAME}.example.com
# PORT - это порт, который слушает приложение ВНУТРИ контейнера.
PORT=${CONTAINER_PORT}
# HOST - это адрес, который слушает приложение ВНУТРИ контейнера. 0.0.0.0 - стандарт для Docker.
HOST=0.0.0.0
ENV
  chown ${DEPLOY_USER}:${DEPLOY_USER} "${WORK_DIR}/.env"
fi

if [ ! -f "${WORK_DIR}/docker-compose.yml" ]; then
  cat > "${WORK_DIR}/docker-compose.yml" <<YML
services:
  bot:
    # Имя образа будет передаваться через переменную окружения BOT_IMAGE во время деплоя
    image: ${BOT_IMAGE:-ghcr.io/${GITHUB_REPOSITORY}:latest}
    env_file:
      - .env
    ports:
      - "${BOT_PORT}:${CONTAINER_PORT}" # Проброс порта с хоста (BOT_PORT) в контейнер (CONTAINER_PORT)
    restart: unless-stopped
    # Ограничиваем использование памяти для защиты сервера
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
    # Явно указываем DNS-серверы для надежного разрешения имен внутри контейнера.
    # Это решает проблему "Temporary failure in name resolution".
    dns:
      - 8.8.8.8
    networks:
      - botnet

networks:
  botnet:
    driver: bridge
YML
  chown ${DEPLOY_USER}:${DEPLOY_USER} "${WORK_DIR}/docker-compose.yml"
fi

echo "Bootstrap completed."
echo "Next steps:"
echo "1. Add the secrets displayed above to your GitHub repository."
echo "2. IMPORTANT: Add your bot's token as a GitHub Secret named 'BOT_TOKEN'."
echo "3. Edit the placeholder values in ${WORK_DIR}/.env on the server (e.g., WEBHOOK_HOST)."
echo "4. Push to the 'main' branch to trigger the deployment."

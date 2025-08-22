#!/bin/bash
# Скрипт для первоначальной настройки сервера для деплоя Telegram-бота.
# Устанавливает Docker, создает пользователя для деплоя и настраивает окружение.
# Usage: sudo DEPLOY_USER=deployer REPO_NAME=my-bots BOT_NAME=bot_main ./bootstrap-server-custom.sh

set -euo pipefail

DEPLOY_USER=${DEPLOY_USER:-deploy}
BOT_NAME=${BOT_NAME:-bot_main}
BOT_PORT=${BOT_PORT:-8001}
CONTAINER_PORT=${CONTAINER_PORT:-8080}
OWNER=${OWNER:-} # This should be set from the command line
REPO_NAME=${REPO_NAME:-} # This should be set from the command line

if [ -z "${OWNER}" ]; then
  echo "Error: GitHub username is not set. Please provide it via the OWNER environment variable."
  echo "Usage: sudo OWNER=your-github-username REPO_NAME=your-repo-name ./bootstrap-server-custom.sh"
  exit 1
fi
if [ -z "${REPO_NAME}" ]; then
  echo "Error: GitHub repository name is not set. Please provide it via the REPO_NAME environment variable."
  echo "Usage: sudo OWNER=your-github-username REPO_NAME=your-repo-name ./bootstrap-server-custom.sh"
  exit 1
fi
# Convert OWNER to lowercase to comply with Docker image naming conventions.
OWNER=${OWNER,,}
REPO_NAME=${REPO_NAME,,}

WORK_DIR=/opt/pybot/${BOT_NAME}

echo "Запуск настройки: WORK_DIR=${WORK_DIR}, DEPLOY_USER=${DEPLOY_USER}, BOT_NAME=${BOT_NAME}"

# install docker (same as generic)
if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker
fi

# create user if not exists
if ! id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
  echo "Пользователь ${DEPLOY_USER} не найден. Создание..."
  useradd -m -s /bin/bash "${DEPLOY_USER}"
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
  echo "WORK_DIR: ${WORK_DIR}"
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
  # rm -f "${KEY_PATH}"
fi

# create layout and permissions
if [ ! -d "${WORK_DIR}" ]; then
    mkdir -p "${WORK_DIR}"
    chown -R ${DEPLOY_USER}:${DEPLOY_USER} "${WORK_DIR}"
fi

# sample env and compose
if [ ! -f "${WORK_DIR}/.env" ]; then
  cat > "${WORK_DIR}/.env" <<ENV
BOT_TOKEN=123456:ABC-DEF-YOUR_TOKEN
# WEBHOOK_HOST должен указывать на уникальный поддомен для этого бота, например https://my-first-bot.your-domain.com
WEBHOOK_HOST=https://${BOT_NAME}.example.com
# PORT - это порт, который слушает приложение ВНУТРИ контейнера.
PORT=${CONTAINER_PORT}
ENV
  chown ${DEPLOY_USER}:${DEPLOY_USER} "${WORK_DIR}/.env"
fi

if [ ! -f "${WORK_DIR}/docker-compose.prod.yml" ]; then
  cat > "${WORK_DIR}/docker-compose.prod.yml" <<YML
services:
  bot:
    image: ghcr.io/${OWNER}/${REPO_NAME}:latest
    env_file:
      - .env
    ports:
      - "${BOT_PORT}:${CONTAINER_PORT}" # Проброс порта с хоста (BOT_PORT) в контейнер (CONTAINER_PORT)
    restart: unless-stopped
    # Ограничиваем использование памяти для защиты сервера
    mem_limit: 150m
    memswap_limit: 300m
    networks:
      - botnet

networks:
  botnet:
    driver: bridge
YML
  chown ${DEPLOY_USER}:${DEPLOY_USER} "${WORK_DIR}/docker-compose.prod.yml"
fi

echo "Bootstrap completed."
echo "Next steps:"
echo "1. Ensure you have added the secrets above to your GitHub repository."
echo "2. Edit the placeholder values in ${WORK_DIR}/.env on the server."
echo "3. Push to the 'main' branch to trigger the deployment."

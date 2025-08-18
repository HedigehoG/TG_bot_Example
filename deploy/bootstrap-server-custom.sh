#!/bin/bash
# Custom bootstrap script tailored for a specific project/user.
# Usage: sudo BOOT_USER=deployuser REPO_NAME=my-bots BOT_NAME=bot_main ./bootstrap-server-custom.sh

set -euo pipefail

BOOT_USER=${BOOT_USER:-deploy}
REPO_NAME=${REPO_NAME:-tg-bot}
BOT_NAME=${BOT_NAME:-bot_main}
OWNER=${OWNER:-} # This should be set from the command line

if [ -z "${OWNER}" ]; then
  echo "Error: GitHub username is not set. Please provide it via the OWNER environment variable."
  echo "Usage: sudo OWNER=your-github-username ./bootstrap-server-custom.sh"
  exit 1
fi
REPO_DIR=/opt/pybot/conf_git/${REPO_NAME}.git
WORK_DIR=/opt/pybot/${BOT_NAME}

echo "Custom bootstrap: REPO=${REPO_DIR}, WORK=${WORK_DIR}, USER=${BOOT_USER}"

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
if ! id -u "${BOOT_USER}" >/dev/null 2>&1; then
  echo "User ${BOOT_USER} not found. Creating..."
  useradd -m -s /bin/bash "${BOOT_USER}"
  # Add user to docker group to manage containers without sudo
  usermod -aG docker "${BOOT_USER}"
  echo "User ${BOOT_USER} created and added to the docker group."

  # Create .ssh directory and authorized_keys file
  SSH_DIR="/home/${BOOT_USER}/.ssh"
  mkdir -p "${SSH_DIR}"
  touch "${SSH_DIR}/authorized_keys"
  chmod 700 "${SSH_DIR}"
  chmod 600 "${SSH_DIR}/authorized_keys"
  chown -R ${BOOT_USER}:${BOOT_USER} "${SSH_DIR}"
  echo "SSH directory for ${BOOT_USER} created."

  # Generate a new SSH key pair for deployment
  echo "Generating a new SSH key for deployment..."
  KEY_PATH="${SSH_DIR}/id_ed25519_deploy"
  ssh-keygen -t ed25519 -f "${KEY_PATH}" -N "" -C "deploy-key-${BOT_NAME}@$(hostname)"

  # Add the public key to authorized_keys
  cat "${KEY_PATH}.pub" >> "${SSH_DIR}/authorized_keys"
  chown -R ${BOOT_USER}:${BOOT_USER} "${SSH_DIR}"
  echo "Deployment key generated and authorized."

  echo "----------------------------------------------------------------"
  echo "ВАЖНО! СКОПИРУЙТЕ ЭТОТ ПРИВАТНЫЙ КЛЮЧ И СОХРАНИТЕ ЕГО."
  echo "Он понадобится для GitHub Actions (секрет SSH_PRIVATE_KEY)."
  echo "После закрытия этого окна ключ будет удален с сервера."
  echo "----------------------------------------------------------------"
  cat "${KEY_PATH}"
  echo "----------------------------------------------------------------"
  # Securely remove the private key from the server after displaying it
  rm -f "${KEY_PATH}"
fi

# create layout and permissions
mkdir -p /opt/pybot/conf_git
mkdir -p "${WORK_DIR}"
chown -R ${BOOT_USER}:${BOOT_USER} /opt/pybot || true

# init bare repo
if [ ! -d "${REPO_DIR}/refs" ]; then
  git init --bare "${REPO_DIR}"
fi

# create post-receive hook tailored
cat > "${REPO_DIR}/hooks/post-receive" <<HOOK
#!/bin/bash
# post-receive for ${BOT_NAME}
TARGET_DIR="${WORK_DIR}"
GIT_DIR="${REPO_DIR}"

echo "Deploying to ${TARGET_DIR}"
mkdir -p ${TARGET_DIR}
git --work-tree=${TARGET_DIR} --git-dir=${GIT_DIR} checkout -f
cd ${TARGET_DIR} || exit

docker compose -f docker-compose.prod.yml pull || true
docker compose -f docker-compose.prod.yml up -d --remove-orphans

echo "Deployed ${BOT_NAME}"
HOOK

chmod +x "${REPO_DIR}/hooks/post-receive"
chown -R ${BOOT_USER}:${BOOT_USER} "${REPO_DIR}"

# sample env and compose
if [ ! -f "${WORK_DIR}/.env" ]; then
  cat > "${WORK_DIR}/.env" <<ENV
BOT_TOKEN=123456:ABC-DEF-YOUR_TOKEN
# WEBHOOK_HOST должен указывать на уникальный поддомен для этого бота, например https://my-first-bot.your-domain.com
WEBHOOK_HOST=https://${BOT_NAME}.example.com
PORT=3000
ENV
  chown ${BOOT_USER}:${BOOT_USER} "${WORK_DIR}/.env"
fi

if [ ! -f "${WORK_DIR}/docker-compose.prod.yml" ]; then
  cat > "${WORK_DIR}/docker-compose.prod.yml" <<YML
version: '3.8'
services:
  bot:
    image: ghcr.io/${OWNER}/tg-webhook-bot:latest
    env_file:
      - .env
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
  chown ${BOOT_USER}:${BOOT_USER} "${WORK_DIR}/docker-compose.prod.yml"
fi

echo "Custom bootstrap completed."
echo "IMPORTANT: Add the private key displayed above to your GitHub repo secrets as SSH_PRIVATE_KEY."
echo "1. Edit secrets in ${WORK_DIR}/.env"
echo "2. Add remote to your local git repo: git remote add live ssh://${BOOT_USER}@$(hostname -f)${REPO_DIR}"
echo "3. Push to deploy: git push live main"

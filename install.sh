#!/bin/bash
set -e

# --- Цвета для вывода ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Установка OpenConnect VPN (ocserv) ===${NC}"

# --- 1. Проверка root ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Запустите скрипт от root (sudo bash install.sh)${NC}"
  exit 1
fi

# --- 2. Проверка Docker и Compose ---
if ! command -v docker &> /dev/null; then
  echo -e "${YELLOW}Docker не найден. Установите Docker и повторите.${NC}"
  exit 1
fi

if ! docker compose version &> /dev/null; then
  echo -e "${YELLOW}Docker Compose plugin не найден.${NC}"
  exit 1
fi

# --- 3. Запрос параметров ---
read -p "Введите внешний порт для VPN [8443]: " VPN_PORT
VPN_PORT=${VPN_PORT:-8443}

read -p "Введите IP или домен сервера (для сертификата) [vpn.local]: " SRV_CN
SRV_CN=${SRV_CN:-vpn.local}

# --- 4. Создание каталогов ---
WORKDIR="/opt/ocserv-oneclick"
mkdir -p "$WORKDIR"/{config,cert,auth}
cd "$WORKDIR"

# --- 5. Генерация docker-compose.yml ---
cat > docker-compose.yml <<EOF
services:
  ocserv:
    image: docker.io/petecovod/ocserv:latest
    container_name: ocserv
    restart: unless-stopped
    ports:
      - "${VPN_PORT}:443/tcp"
      - "${VPN_PORT}:443/udp"
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun
    volumes:
      - ./config:/etc/ocserv/config
      - ./cert:/etc/ocserv/cert
      - ./auth:/etc/ocserv/auth
    environment:
      - VPN_SUBNET=10.10.10.0/24
      - SRV_CN=${SRV_CN}
      - SRV_CA=VPN CA
      - ENABLE_DTLS=true
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"
EOF

# --- 6. Копирование шаблона конфига (если есть) ---
if [ -f "./ocserv.conf.template" ]; then
  cp ./ocserv.conf.template ./config/ocserv.conf
  echo -e "${GREEN}Шаблон конфига скопирован.${NC}"
else
  echo -e "${YELLOW}Шаблон ocserv.conf не найден — контейнер сгенерирует базовый.${NC}"
fi

# --- 7. Включение IP forwarding ---
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-vpn.conf
sysctl -p /etc/sysctl.d/99-vpn.conf > /dev/null

# --- 8. Запуск ---
echo -e "${YELLOW}Запуск контейнера...${NC}"
docker compose up -d

sleep 3

# --- 9. Проверка, что запустился ---
if ! docker ps --format '{{.Names}}' | grep -q '^ocserv$'; then
  echo -e "${RED}Контейнер не запустился. Логи:${NC}"
  docker logs --tail 30 ocserv
  exit 1
fi

echo -e "${GREEN}✅ VPN-сервер запущен на порту ${VPN_PORT}${NC}"

# --- 10. Создание первого пользователя ---
echo ""
echo -e "${YELLOW}=== Создание первого пользователя ===${NC}"
read -p "Введите имя пользователя: " USERNAME
if [ -n "$USERNAME" ]; then
  echo "Введите пароль для $USERNAME (дважды):"
  docker exec -it ocserv ocs user add "$USERNAME"
  echo -e "${GREEN}✅ Пользователь $USERNAME создан.${NC}"
fi

# --- 11. Финальная подсказка ---
echo ""
echo -e "${GREEN}=== Готово! ===${NC}"
echo "Сервер: https://${SRV_CN}:${VPN_PORT}"
echo "Клиент: Cisco Secure Client (iPhone/Android/ПК)"
echo ""
echo "Добавить пользователя позже:"
echo "  docker exec -it ocserv ocs user add <имя>"

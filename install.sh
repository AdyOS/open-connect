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

# --- 1.5. Очистка предыдущей установки (если была) ---
echo -e "${YELLOW}Очистка предыдущих запусков...${NC}"
# Останавливаем и удаляем контейнер, если он есть
docker rm -f ocserv 2>/dev/null || true
# Удаляем временные файлы, если остались от прошлых запусков
rm -f ./config/ocserv.conf.tmp ./merged.conf

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

# Автоматически определяем внешний IP сервера
echo -n "Определение внешнего IP... "
DETECTED_IP=$(curl -s -4 ifconfig.me || curl -s -4 icanhazip.com || curl -s -4 api.ipify.org)
if [ -n "$DETECTED_IP" ]; then
    echo -e "${GREEN}[$DETECTED_IP]${NC}"
else
    echo -e "${YELLOW}[не удалось определить, потребуется ввод вручную]${NC}"
    DETECTED_IP="vpn.local"
fi

read -p "Введите IP или домен сервера (для сертификата) [$DETECTED_IP]: " SRV_CN
SRV_CN=${SRV_CN:-$DETECTED_IP}

# --- 4. Подготовка каталогов в текущей папке ---
# Скрипт ожидает запуск из корня репозитория (где лежат install.sh и папка config)
mkdir -p ./config ./cert ./auth

# Проверяем, что пользовательский конфиг с no-route на месте
CUSTOM_CONF="./config/ocserv.conf"
if [ ! -f "$CUSTOM_CONF" ]; then
  echo -e "${YELLOW}Внимание: файл $CUSTOM_CONF не найден! VPN будет без правил исключения.${NC}"
  # Создаем пустой, чтобы Docker не ругался на монтирование
  touch "$CUSTOM_CONF"
fi

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

# --- 6. Включение IP forwarding ---
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-vpn.conf
sysctl -p /etc/sysctl.d/99-vpn.conf > /dev/null

# --- 7. Первый запуск контейнера (генерация базового конфига и сертификатов) ---
echo -e "${YELLOW}Запуск контейнера и генерация сертификатов...${NC}"

# Временно скрываем наш кастомный конфиг, чтобы контейнер сгенерировал свой базовый
if [ -s "$CUSTOM_CONF" ]; then
    mv "$CUSTOM_CONF" "${CUSTOM_CONF}.tmp"
    touch "$CUSTOM_CONF"
fi

docker compose up -d
sleep 5

# --- 8. Внедрение правил no-route ---
if [ -s "${CUSTOM_CONF}.tmp" ]; then
    echo -e "${YELLOW}Добавление правил маршрутизации (no-route)...${NC}"
    
    # Базовый конфиг (сгенерированный) берем за основу
    cp "${CUSTOM_CONF}.tmp" ./merged.conf
    
    # Добавляем пустую строку и комментарий-разделитель
    echo "" >> ./merged.conf
    echo "# --- Пользовательские правила no-route ---" >> ./merged.conf
    
    # Дописываем файл с no-route в конец
    cat "$CUSTOM_CONF" >> ./merged.conf
    
    # Заменяем файл в папке config
    mv ./merged.conf "$CUSTOM_CONF"
    
    # Удаляем временный файл
    rm -f "${CUSTOM_CONF}.tmp"
    
    # Перезапускаем контейнер для применения новых правил
    echo -e "${YELLOW}Применение новых настроек (перезапуск)...${NC}"
    docker compose down
    docker compose up -d
    sleep 3
fi

# --- 9. Проверка, что запустился ---
if ! docker ps --format '{{.Names}}' | grep -q '^ocserv$'; then
  echo -e "${RED}Контейнер не запустился. Логи:${NC}"
  docker logs --tail 30 ocserv
  exit 1
fi

echo -e "${GREEN}✅ VPN-сервер запущен на порту ${VPN_PORT}${NC}"

# --- 10. Инструкция по созданию пользователя ---
echo ""
echo -e "${YELLOW}=== Создание первого пользователя ===${NC}"
echo "Установка завершена. Чтобы создать пользователя, выполните команду:"
echo ""
echo -e "${GREEN}docker exec -it ocserv ocs user add <имя_пользователя>${NC}"
echo ""
echo "Например:"
echo "  docker exec -it ocserv ocs user add my_vpn"
echo ""
echo "После ввода команды система запросит пароль (дважды)."

# --- 11. Финальная подсказка ---
echo ""
echo -e "${GREEN}=== Готово! ===${NC}"
echo "Сервер: https://${SRV_CN}:${VPN_PORT}"
echo "Клиент: Cisco Secure Client (iPhone/Android/ПК)"
echo ""
echo "Добавить пользователя позже:"
echo "  docker exec -it ocserv ocs user add <имя>"

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

# --- 1.5. Очистка предыдущей установки ---
echo -e "${YELLOW}Очистка предыдущих запусков...${NC}"
docker rm -f ocserv 2>/dev/null || true
# Удаляем только рабочий конфиг, шаблон не трогаем
rm -f ./config/ocserv.conf ./merged.conf

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

# --- 4. Подготовка каталогов ---
mkdir -p ./config ./cert ./auth
CUSTOM_CONF="./config/ocserv.conf"

# Проверяем, что шаблон с no-route на месте
if [ ! -f "./config/ocserv.conf.template" ]; then
  echo -e "${YELLOW}Внимание: файл config/ocserv.conf.template не найден! VPN будет без правил исключения.${NC}"
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

# --- 7. Первый запуск контейнера (генерация базового конфига) ---
echo -e "${YELLOW}Запуск контейнера и генерация сертификатов...${NC}"

# Убеждаемся, что файла нет (только что удалили), чтобы контейнер его создал
docker compose up -d
sleep 5

# Проверяем, что базовый конфиг сгенерировался и в нем есть auth
if [ ! -f "$CUSTOM_CONF" ] || ! grep -q "auth =" "$CUSTOM_CONF"; then
    echo -e "${RED}Ошибка: контейнер не сгенерировал корректный базовый конфиг! Логи:${NC}"
    docker logs --tail 30 ocserv
    exit 1
fi

# --- 8. Внедрение правил no-route ---
if [ -f "./config/ocserv.conf.template" ]; then
    echo -e "${YELLOW}Добавление правил маршрутизации (no-route)...${NC}"
    
    # Базовый конфиг берем за основу
    cp "$CUSTOM_CONF" ./merged.conf
    
    # Добавляем пустую строку и комментарий-разделитель
    echo "" >> ./merged.conf
    echo "# --- Пользовательские правила no-route ---" >> ./merged.conf
    
    # Дописываем ВАШ шаблон с no-route в конец
    cat "./config/ocserv.conf.template" >> ./merged.conf
    
    # Заменяем рабочий конфиг на слитый
    mv ./merged.conf "$CUSTOM_CONF"
    
    # Перезапускаем
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

# OpenConnect VPN — установка в одну команду

## Требования
- VPS с Ubuntu/Debian
- Docker + Docker Compose plugin
- Открытый порт (по умолчанию 8443, TCP+UDP)

## Установка
```bash
git clone https://github.com/AdyOS/ocserv-oneclick.git
cd ocserv-oneclick
sudo bash install.sh
```
## Подключение
- iPhone/Android: Cisco Secure Client
- ПК: OpenConnect GUI
- Адрес: https://IP:порт (обязательно с https://)
- В настройках клиента выключить Блокировать ненадежные серверы

## Добавление пользователя
```bash
docker exec -it ocserv ocs user add имя_пользователя
```

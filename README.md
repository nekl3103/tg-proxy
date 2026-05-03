# TG Proxy Manager

Установщик и менеджер для официального Docker-образа Telegram MTProto Proxy:

- image: `telegrammessenger/proxy:latest`
- persistent `SECRET`
- optional `TAG` for @MTProxybot sponsorship
- command name: `tg`

## Быстрый запуск

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/nekl3103/tg-proxy/main/install.sh)"
```

## Установка вручную

```bash
sudo curl -fsSL https://raw.githubusercontent.com/nekl3103/tg-proxy/main/install.sh -o /usr/local/bin/tg
sudo chmod +x /usr/local/bin/tg
sudo tg install
```

## Команды

```bash
tg status
tg links
tg logs
tg restart
tg stop
tg start
tg config show
tg config edit
tg config secret <secret>
tg config tag <tag>
tg update
tg uninstall
```

## Примечания

- `SECRET` должен быть 32 символа в lowercase hex.
- `TAG` можно оставить пустым.
- Логи и статистика берутся из официального локального endpoint контейнера.

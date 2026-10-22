# Radmin VPN для macOS

Запуск [Radmin VPN](https://www.radmin-vpn.com/) на Mac (Apple Silicon и Intel): сети,
участники, игры по локальной сети — без виртуальной машины с Windows.

Это порт проекта [**radmin-vpn-linux**](https://github.com/baptisterajaut/radmin-vpn-linux)
от [**@baptisterajaut**](https://github.com/baptisterajaut). Вся основная работа — обратная
разработка драйвера Radmin, Wine-драйвер `rvpnnetmp.sys`, хуки, мост — сделана там, вместе
с [участниками того проекта](README-linux.md#credits). Здесь добавлено то, что нужно
macOS: виртуальный сетевой адаптер на `feth`, запуск через CrossOver/Wine и правки
отображения окна. Linux-часть сохранена без изменений, её описание — в
[README-linux.md](README-linux.md).

> Radmin VPN — проприетарная программа Famatech Corp. Этот проект с Famatech не связан
> и не содержит и не распространяет её код: установщик скачивается с radmin-vpn.com и
> сверяется по sha256. Используйте на свой страх и риск, без гарантий.

## Как это работает

Оригинальный Radmin VPN для Windows запускается под Wine. Его драйвер сетевого адаптера
заменён нашим, который передаёт кадры в macOS:

```
macOS ← feth26 ⇄ feth5026 ← tap_bridge (BPF/NDRV) ← FIFO ← rvpnnetmp.sys (Wine) ← RvControlSvc.exe
```

TAP-устройства в macOS нет, поэтому используется пара виртуальных ethernet-интерфейсов
`feth` (тот же приём, что у ZeroTier). Система видит `feth26` с адресом 26.x, а мост читает
кадры с `feth5026` через BPF и отправляет обратно через AF_NDRV. Расширения ядра не нужны.

## Что нужно

1. **Rosetta 2** (только Apple Silicon), Wine исполняет x86_64-код:
   ```bash
   softwareupdate --install-rosetta --agree-to-license
   ```
2. **CrossOver 26 или новее** (проверено на 26.1). Скрипт сам создаёт бутылку `RadminVPN`.
   Бесплатный Wine от Gcenx (`Wine Devel` 11.18) **не подходит**: он падает в установщике
   Radmin (32-битный SEH под wow64 + Rosetta, `Exception frame is not in stack limits`).
   Другие варианты: `RVPN_WINE=system` — Wine из `PATH` или `Wine Devel.app`,
   `WINE_BIN_DIR=/path/to/wine/bin` — свой Wine.
3. **mingw-w64** для сборки Windows-части: `brew install mingw-w64`.
4. Права администратора (sudo) для интерфейсов `feth`, BPF и маршрутов.

## Установка и запуск

```bash
git clone https://github.com/Andr00id/radmin-vpn-macos.git
cd radmin-vpn-macos
make -f Makefile.macos
./run_macos.sh
```

При первом запуске скрипт скачивает проверенную версию Radmin (2.1.4951.1), сверяет sha256
и ставит её в бутылку CrossOver. Дальше `./run_macos.sh` просто поднимает VPN и открывает
окно Radmin. Закрытие окна или Ctrl+C останавливает всё: интерфейсы удаляются, маршруты
возвращаются на место. Это происходит, даже если просто закрыть окно терминала: уборку
доделывает фоновый `macos_guard.sh`, запущенный от root.

Если во время работы падает мост или служба Radmin (в игре это выглядит как «друзья
онлайн, но не подключиться»), скрипт сам перезапускает VPN. Сдаётся он только после трёх
падений подряд.

| Флаг | Что делает |
|---|---|
| `--installer <путь>` | свой установщик Radmin (только при первом запуске) |
| `--no-ui` | запустить только службу, без окна |
| `--update` | обновить Radmin до проверенной версии; Radmin ID сохраняется |
| `--no-broadcast-routes` | не переводить broadcast/multicast на VPN |
| `--no-retina` | рисовать окно в обычном разрешении |

## Если что-то не так

- **Участники подключаются медленно или через ретранслятор** (200+ мс, в логе `TcpRelay`):
  выключите другой VPN или прокси. Если маршрут по умолчанию идёт через `utunN`, Radmin
  не может установить прямое соединение.
- **Служба зарегистрировалась, но не стала «ready»**: та же причина. Исключите
  `26.0.0.0/8` и `*.radminte.com` из туннеля или выключите его.
- **`cannot peer feth26`**: остались интерфейсы от упавшего запуска:
  `sudo ifconfig feth26 destroy; sudo ifconfig feth5026 destroy`.
- **После VPN не работает поиск устройств в домашней сети** (Chromecast, AirPlay): маршруты
  broadcast/multicast не вернулись на Wi-Fi. Следующий запуск `./run_macos.sh` восстановит
  их сам; сразу — выключите и включите Wi-Fi.
- **Окно выглядит неправильно**: попробуйте `--no-retina`.
- **Логи**: `/tmp/radmin_bridge.log`, `radmin_driver.log`, `radmin_service.log`,
  `radmin_relay.log`, `radmin_gui.log`. Если служба не поднялась, скрипт сам выводит сводку.
  Подробные логи Wine: `RVPN_SVC_WINEDEBUG=+seh,+tid ./run_macos.sh`.

## Что изменено относительно radmin-vpn-linux

Изменения сделаны в октябре 2026 года, основа — коммит `7543895` исходного проекта.

- `src/tap_bridge.c` — macOS-бэкенд: пара `feth`, чтение через BPF, запись через AF_NDRV;
  FIFO передаются пользователю, запустившему sudo. Записи `[длина][кадр]` никогда не рвутся
  на части (в macOS `PIPE_BUF` = 512 байт); переполнение очереди интерфейса теряет пакет, а
  не останавливает мост; очередь на запись сохраняет порядок кадров; файлы в `/tmp`
  создаются и читаются без перехода по символическим ссылкам. Linux-ветка работает как раньше.
- `src/adapter_hook.c` — имя хост-интерфейса берётся из `RVPN_TAP_NAME` (по умолчанию
  `radminvpn0`), поэтому одна PE-сборка подходит обеим ОС.
- `src/rvpnnetmp.c` — отладочная строка `WR mac=` пишется в лог трижды, а не на каждый пакет.
- `run_macos.sh` (новый) — запуск под macOS: CrossOver или Wine, `feth`, маршруты с
  проверкой и возвратом на место, разбор команд `netsh` без root-оболочки, настоящая
  Tahoma из macOS вместо заглушки Wine, Retina-режим, перезапуск при падении.
- `macos_guard.sh` (новый) — уборка от root после выхода скрипта, даже без терминала.
- `Makefile.macos` (новый) — сборка clang + mingw-w64 из Homebrew.
- `README.md` — этот файл; исходный README перенесён в `README-linux.md`.

Порт сделан с помощью Claude (Anthropic), как и исходный проект.

## Лицензия

[GPL-3.0](LICENSE), как и у исходного проекта. Copyright принадлежит авторам
radmin-vpn-linux и участникам этого порта.

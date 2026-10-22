# Radmin VPN для macOS

Запуск [Radmin VPN](https://www.radmin-vpn.com/) на Mac (Apple Silicon и Intel): сети,
участники, игры по локальной сети — без виртуальной машины с Windows.

Это порт проекта [**radmin-vpn-linux**](https://github.com/baptisterajaut/radmin-vpn-linux)
от [**@baptisterajaut**](https://github.com/baptisterajaut). Вся основная работа — обратная
разработка драйвера Radmin, Wine-драйвер `rvpnnetmp.sys`, хуки, мост — сделана там, вместе
с [участниками того проекта](README-linux.md#credits). Здесь добавлено то, что нужно
macOS: виртуальный сетевой адаптер на `feth`, запуск на бесплатном Wine (с исправлением
для Rosetta) и правки отображения окна. Linux-часть сохранена, её описание — в
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

## Быстрый старт (готовый архив)

1. **Rosetta 2** (только Apple Silicon), Wine исполняет x86_64-код:
   ```bash
   softwareupdate --install-rosetta --agree-to-license
   ```
2. Скачайте `radmin-vpn-macos-<версия>.zip` со страницы
   [Releases](https://github.com/Andr00id/radmin-vpn-macos/releases/latest) и распакуйте.
3. В Терминале:
   ```bash
   cd ~/Downloads/radmin-vpn-macos-*
   ./run_macos.sh
   ```

Больше ничего ставить не нужно: при первом запуске скрипт сам скачивает бесплатный Wine
(Wine Devel 11.18, ~190 МБ) и Radmin VPN 2.1.4951.1, проверяет sha256 каждого файла и
устанавливает. Пароль администратора (sudo) нужен для сетевых интерфейсов, BPF и маршрутов.
Ваши данные — Wine, префикс с Radmin ID — лежат в
`~/Library/Application Support/radmin-vpn-macos/`, так что новую версию архива можно
просто распаковать рядом: ID и сети сохранятся.

## Сборка из исходников

Нужны Xcode Command Line Tools (`xcode-select --install`) и mingw-w64:

```bash
brew install mingw-w64
git clone https://github.com/Andr00id/radmin-vpn-macos.git
cd radmin-vpn-macos
make -f Makefile.macos
./run_macos.sh
```

`make` один раз скачивает заголовки Wine 11.18 для сборки `wow64cpu.dll`. Свой архив, как
на странице Releases: `./packaging/package-macos.sh` (результат в `packaging/dist/`). Его же
собирает GitHub Actions при каждом пуше, а по тегу `v*` публикует релиз.

## Как устроен запуск

Radmin VPN ставится не через свой установщик, а напрямую из MSI-пакета внутри него
(достаётся утилитой [innounp](https://github.com/jrathlev/InnoUnpacker-Windows-GUI)): обёртка
Inno Setup под Wine на macOS падает. Скрипт держит собственную копию Wine в папке данных и
заменяет в ней `wow64cpu.dll` на собранную из `src/wow64cpu/cpu.c`: в обычном Wine
переключение 32↔64-бит под Rosetta иногда срабатывает неправильно, и любая 32-битная
программа с окном — окно Radmin, его установщик — падает. Исправление то же, что применяет
CrossOver: дальний вызов/возврат вместо дальнего перехода.

Если раньше вы пользовались этим портом через CrossOver, при первом запуске Radmin ID, имя,
сети и MAC переносятся из бутылки `RadminVPN` автоматически. Перенести принудительно:
`./run_macos.sh --import-crossover-id`. Запустить по-старому через CrossOver:
`RVPN_WINE=crossover ./run_macos.sh`.

После запуска `./run_macos.sh` поднимает VPN и открывает окно Radmin. Закрытие окна или Ctrl+C останавливает всё: интерфейсы удаляются, маршруты
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
| `--import-crossover-id` | заменить Radmin ID на тот, что в бутылке CrossOver `RadminVPN` |

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
- `src/wow64cpu/cpu.c` (новый) — `dlls/wow64cpu/cpu.c` из Wine 11.18 (LGPL-2.1+) с режимом
  для Rosetta: lcall/lretq вместо ljmp при переключении 32↔64-бит.
- `run_macos.sh` (новый) — запуск под macOS: своя копия Wine с исправленным `wow64cpu.dll`,
  установка Radmin из MSI, перенос ID из CrossOver, `feth`, маршруты с проверкой и
  возвратом на место, разбор команд `netsh` без root-оболочки, настоящая Tahoma из macOS
  вместо заглушки Wine, Retina-режим, перезапуск при падении.
- `macos_guard.sh` (новый) — уборка от root после выхода скрипта, даже без терминала.
- `Makefile.macos` (новый) — сборка clang (universal: arm64 + x86_64) + mingw-w64.
- `packaging/package-macos.sh`, `.github/workflows/macos.yml` (новые) — архив и релизы.
- `lib.sh` — `scrub_ndis_driver` ждёт выхода wineserver (`wineserver -w`) перед правкой реестра.
- `README.md` — этот файл; исходный README перенесён в `README-linux.md`.

Порт сделан с помощью Claude (Anthropic), как и исходный проект.

## Лицензия

[GPL-3.0](LICENSE), как и у исходного проекта. Copyright принадлежит авторам
radmin-vpn-linux и участникам этого порта. `src/wow64cpu/cpu.c` — код Wine под
LGPL-2.1-or-later (Copyright 2021 Alexandre Julliard), с нашими изменениями.

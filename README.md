# FastConnect

`FastConnect` — нативное menubar-приложение для macOS, которое управляет Cisco AnyConnect Secure Mobility Client через штатный CLI `/opt/cisco/anyconnect/bin/vpn`.

Приложение закрывает типовой сценарий:
- один раз сохранить параметры подключения;
- хранить секрет для генерации TOTP;
- включать запуск при входе в систему;
- подключать и отключать VPN одним кликом;
- показывать текущий статус в tray bar;
- писать логи и открывать папку с логами из настроек.

## Возможности

- Menubar-приложение без Dock icon (`LSUIElement`).
- Контекстное меню:
  - `Подключить`
  - `Подключено` или `Подключение...`
  - `Отключить`
  - `Настройки...`
  - `Выйти`
- Две иконки состояния:
  - `Disconnected.icns` для отключенного VPN и иконки `.app`
  - `Connected.icns` для активного VPN
- Окно настроек с полями:
  - `VPN host`
  - `Номер профиля`
  - `Логин`
  - `Пароль`
  - `TOTP secret`
  - `Запускать при входе в систему`
- Локальные уведомления:
  - `Подключение началось`
  - `VPN подключен`
  - `Началось отключение`
  - `Отключен VPN`
- Логирование в файлы по дням.

## Как работает подключение

Приложение использует режим `vpn -s` и подаёт ответы в stdin в таком порядке:

```text
connect <VPN host>
<номер профиля>
<логин>
<пароль>
<пароль>
<TOTP>
```

После команды `connect` приложение дополнительно запрашивает `vpn state` и считает подключение успешным только если CLI вернул `state: Connected`.

## Архитектура

- Язык: `Swift 6`
- UI: `AppKit` + `SwiftUI` для окна настроек
- Хранение секретов: `Keychain`
- Автозапуск: `ServiceManagement`
- Уведомления: `UserNotifications`
- Сборка проекта: `Xcode` / `xcodebuild`

Основные файлы:

- `FastConnect/Sources/AppDelegate.swift` — menubar, меню, запуск приложения, завершение с предварительным disconnect
- `FastConnect/Sources/AppState.swift` — состояние приложения, connect/disconnect, синхронизация статуса
- `FastConnect/Sources/VPNService.swift` — обёртка над Cisco AnyConnect CLI
- `FastConnect/Sources/SettingsStore.swift` — загрузка и сохранение конфигурации
- `FastConnect/Sources/KeychainService.swift` — работа с Keychain
- `FastConnect/Sources/TOTPGenerator.swift` — генерация TOTP
- `FastConnect/Sources/AppNotificationService.swift` — локальные уведомления
- `FastConnect/Sources/AppLogger.swift` — логирование
- `FastConnect/Sources/SettingsView.swift` — UI настроек

## Хранение данных

В `Keychain` сохраняются:

- логин
- пароль
- TOTP secret

В `UserDefaults` сохраняются только несекретные данные:

- `VPN host`
- `Номер профиля`
- флаг автозапуска

## Логи

Логи пишутся в:

```text
~/Library/Logs/FastConnect/
```

Формат:

- один файл на день, например `2026-03-24.log`
- уровень (`INFO`, `ERROR`)
- категория (`AppDelegate`, `AppState`, `VPNService`, `Notifications`)

Папку с логами можно открыть из окна настроек.

## Поведение при запуске и завершении

- При старте приложение сразу читает `vpn state`.
- Если туннель уже поднят, menubar-иконка сразу переключается в состояние `Connected`.
- Если пользователь запрашивает выход при активном туннеле, приложение сначала вызывает `disconnect`, дожидается отключения и только потом завершает процесс.

## Сборка и запуск

Требования:

- macOS
- установленный `Xcode`
- установленный Cisco AnyConnect с CLI по пути `/opt/cisco/anyconnect/bin/vpn`

Открыть проект:

```bash
open FastConnect.xcodeproj
```

Сборка из терминала:

```bash
xcodebuild -project FastConnect.xcodeproj -scheme FastConnect -configuration Debug -derivedDataPath .signedbuild build
```

Запуск собранного приложения:

```bash
open .signedbuild/Build/Products/Debug/FastConnect.app
```

Важно:

- для проверки уведомлений используй именно обычную signed debug-сборку из Xcode или из `.signedbuild`;
- не запускай сборку, собранную с `CODE_SIGNING_ALLOWED=NO`, если нужен корректный prompt разрешений уведомлений.

## Готовый билд

В репозитории лежит готовый архив для распространения:

- `dist/FastConnect-macos-arm64-release.zip`
- `dist/FastConnect-macos-arm64-release.zip.sha256`

Это `Release`-сборка для `macOS arm64`.

Нюансы распространения:

- архив собран локально и подписан как `Sign to Run Locally`;
- приложение не notarized;
- на машинах коллег macOS может запросить подтверждение первого запуска через `Open` в контекстном меню или через настройки безопасности.

## Ограничения

- Приложение рассчитано на конкретный CLI-flow AnyConnect с выбором профиля по номеру.
- Если VPN-шлюз начнёт задавать дополнительные вопросы или изменит порядок prompt-ов, нужно будет доработать `VPNService.swift`.
- Уведомления зависят от системных настроек macOS для текущего bundle identifier.

## Безопасность и приватность репозитория

В репозиторий не должны попадать:

- build-артефакты
- signed build output
- лог-файлы
- Xcode user data
- локальные временные файлы

Это исключено через `.gitignore`.

В проекте не хранятся реальные креды, реальные TOTP secret и реальные локальные логи. Перед публикацией из UI-строк удалены реальные примеры VPN endpoint-ов.

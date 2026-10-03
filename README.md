# Soundflow

Нативное приложение для macOS (14.2+): громкость и устройство вывода для каждого приложения, мульти-выходы, профили, карта вывода. Дизайн — `design/app.pen` (Pencil).

## Сборка

```sh
brew install xcodegen          # если ещё не установлен
xcodegen generate              # создаёт Soundflow.xcodeproj из project.yml
xcodebuild -scheme Soundflow -configuration Debug build
xcodebuild -scheme Soundflow test
```

Собирайте в стандартный DerivedData: папка `Documents` синхронизируется с iCloud и добавляет файлам атрибуты, из-за которых `codesign` падает.

## Как это работает

- Перехват звука — Core Audio Process Taps (`CATapDescription`, `mutedWhenTapped`). Для каждого приложения с изменённой громкостью или выходом создаётся tap и приватный агрегат из выбранных устройств; IOProc в `RenderState` применяет громкость, баланс и нормализацию. Приложения с настройками по умолчанию звучат напрямую, без накладных расходов.
- Нужно разрешение «Запись системного звука». Отладочная сборка подписана ad-hoc, поэтому после каждой пересборки macOS может спросить его заново.
- Настройки хранятся в `~/Library/Application Support/Soundflow/config.json`.
- В DEBUG-сборке аргумент `-SFScreen map|app|device|multi|profile|menubar|toast|settings:<tab>|onboarding:<step>` сразу открывает нужный экран.

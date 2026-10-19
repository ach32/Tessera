# Tessera

[English](#english) · [Русский](#русский)

![Tessera](Resources/AppIcon-1024.png)

## English

Tessera shows what is taking up disk space on macOS. A folder's contents are
drawn as a map of rectangles: the bigger the file or folder, the bigger its rectangle.
Large files stand out at a glance, with no need to hunt for them in a list.

### Installation

1. Download `Tessera-<version>.dmg` from the [Releases](../../releases) page.
2. Open the DMG and drag Tessera into Applications.
3. On first launch, right-click Tessera and choose Open.
   The app is not signed with an Apple certificate, so macOS blocks a normal
   double-click the first time.

Requires macOS 13 or later. Runs on Apple silicon and Intel.

For Tessera to see the whole disk, grant it full access: System Settings →
Privacy & Security → Full Disk Access → add Tessera.
Without it, system folders and other users' folders show up on the map as "unknown" space.

### Features

- The map builds while scanning, so there's no need to wait for it to finish.
- Double-click a folder to zoom into it, ⌫ goes back.
  ⌘− and ⌘+ change how many nesting levels are visible at once.
- Shows free disk space and space that is used but not visible
  (for example, APFS snapshots or folders without access).
- If files change while the app is running, the map updates itself.
- Filters: `*.jpg` shows only images, `>100mb` only large files,
  `>1year` things that haven't changed in a long time. Combine conditions with `;`.
  Details in Help › Filtering.
- Color tags (keys 1–4) to mark things to delete or move later.
- Context menu: open, show in Finder, Quick Look with Space,
  copy path, move to Trash.
- Scan results can be saved to a file and opened later.
  File lists can be exported to CSV and text.
- Interface in English and Russian.

### Command line

A scan can run without the UI, for example to find large disk images in
Downloads and save the list to CSV:

```bash
/Applications/Tessera.app/Contents/MacOS/Tessera scan ~/Downloads filter "*.dmg;>100mb" \
    export "Files as CSV" ~/big-dmgs.csv autoclose
```

### Building from source

Requires Xcode 15 or the Command Line Tools (`xcode-select --install`).

```bash
swift test                  # tests
bash scripts/build-app.sh   # builds build/Tessera.app
bash scripts/make-dmg.sh    # builds build/Tessera-<version>.dmg
```

## Русский

Tessera показывает, чем занят диск на MacOS. Содержимое папки рисуется как карта из
прямоугольников: чем больше файл или папка, тем больше прямоугольник. Крупные файлы
видно сразу, искать их по списку не нужно.

### Установка

1. Скачайте `Tessera-<версия>.dmg` со страницы [Releases](../../releases).
2. Откройте DMG и перетащите Tessera в «Программы».
3. При первом запуске нажмите на Tessera правой кнопкой и выберите «Открыть».
   Приложение не подписано сертификатом Apple, поэтому обычный двойной клик macOS
   в первый раз заблокирует.

Нужна macOS 13 или новее. Работает на Apple silicon и Intel.

Чтобы Tessera видела весь диск, дайте ей полный доступ: Системные настройки →
Конфиденциальность и безопасность → Полный доступ к диску → добавьте Tessera.
Без этого системные и чужие папки останутся на карте «неизвестным» местом.

### Возможности

- Карта строится по ходу сканирования, ждать конца не обязательно.
- Двойной клик по папке открывает её крупнее, ⌫ возвращает назад.
  ⌘− и ⌘+ меняют, сколько уровней вложенности видно сразу.
- Показывает свободное место на диске и место, которое занято, но не видно
  (например, снимки APFS или папки без доступа).
- Если файлы меняются во время работы, карта обновляется сама.
- Фильтры: `*.jpg` покажет только картинки, `>100mb` только большие файлы,
  `>1year` то, что давно не меняли. Условия можно сочетать через `;`.
  Подробности в меню Help › Filtering.
- Цветные метки (клавиши 1–4), чтобы отмечать то, что потом удалить или перенести.
- Контекстное меню: открыть, показать в Finder, просмотр по пробелу,
  скопировать путь, переместить в Корзину.
- Результаты сканирования можно сохранить в файл и открыть позже.
  Есть экспорт списка файлов в CSV и текст.
- Интерфейс на русском и английском.

### Командная строка

Сканирование можно запустить без интерфейса, например, чтобы найти большие образы
в «Загрузках» и сохранить список в CSV:

```bash
/Applications/Tessera.app/Contents/MacOS/Tessera scan ~/Downloads filter "*.dmg;>100mb" \
    export "Files as CSV" ~/big-dmgs.csv autoclose
```

### Сборка из исходников

Нужны Xcode 15 или Command Line Tools (`xcode-select --install`).

```bash
swift test                  # тесты
bash scripts/build-app.sh   # собирает build/Tessera.app
bash scripts/make-dmg.sh    # собирает build/Tessera-<версия>.dmg
```

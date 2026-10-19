TESSERA — карта места на диске для macOS
=========================================

УСТАНОВКА
1. Перетащите Tessera в папку «Программы» (Applications) — она рядом в этом окне.
2. Откройте «Программы» и дважды щёлкните Tessera.

ПЕРВЫЙ ЗАПУСК
Это тестовая сборка без подписи Apple, поэтому macOS её сначала не пустит.
Сделать нужно один раз:

  • macOS 15 и новее: появится окно «Tessera не открыта». Нажмите «Готово».
    Откройте Системные настройки › Конфиденциальность и безопасность,
    пролистайте вниз и нажмите «Всё равно открыть» рядом с Tessera.
    Подтвердите паролем и ещё раз нажмите «Открыть».

  • macOS 13–14: щёлкните Tessera правой кнопкой › «Открыть» › «Открыть».

  • Если macOS пишет, что приложение «повреждено», выполните в Терминале:
        xattr -dr com.apple.quarantine /Applications/Tessera.app
    и откройте снова.

ПОЛНЫЙ ДОСТУП К ДИСКУ (чтобы видеть весь диск)
Tessera › Настройки › Основные › «Открыть Системные настройки»,
включите Tessera в списке «Полный доступ к диску», перезапустите Tessera
и нажмите «Проверить». Часть системных папок всё равно останется закрытой —
это нормально.

Язык интерфейса: Tessera › Настройки › Основные › Язык.
Найдёте ошибку — откройте Окно › Лог › «Копировать всё» и пришлите текст.


-------------------------------------------------------------------------------
TESSERA — see where your disk space went (macOS 13+)

1. Drag Tessera to Applications. 2. Open it.
This test build isn't signed by Apple, so macOS blocks the first launch:
  • macOS 15+: click Done, then System Settings › Privacy & Security › "Open Anyway".
  • macOS 13–14: right-click Tessera › Open › Open.
  • "Damaged" message: run  xattr -dr com.apple.quarantine /Applications/Tessera.app
Full Disk Access: Tessera › Settings › General › Open System Settings, turn Tessera on,
relaunch, click Check Again.

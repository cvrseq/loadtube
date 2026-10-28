LoadTube — установка / Installation
====================================

1. Перетащите LoadTube в папку Applications.
   Drag LoadTube into the Applications folder.

2. Откройте LoadTube из Applications.
   Open LoadTube from Applications.

Первый запуск / First launch
----------------------------
Если macOS предупреждает, что разработчик не подтверждён:
  Нажмите на LoadTube правой кнопкой → «Открыть» → «Открыть».

If macOS warns that the developer cannot be verified:
  Right-click LoadTube → Open → Open.

При первом запуске приложение скачает yt-dlp и ffmpeg (~120 МБ)
в ~/Library/Application Support/LoadTube/bin. Homebrew не нужен.
On first launch the app downloads yt-dlp and ffmpeg (~120 MB) into
~/Library/Application Support/LoadTube/bin. No Homebrew required.

Если YouTube перестанет скачиваться / If downloads stop working
---------------------------------------------------------------
Удалите папку с инструментами и перезапустите установку:
  rm -rf "$HOME/Library/Application Support/LoadTube/bin"

The app will offer to install the tools again on next launch.

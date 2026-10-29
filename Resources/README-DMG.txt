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

Tidal
-----
Для Tidal нужен собственный аккаунт. Вход — по коду на сайте Tidal,
пароль вводится только там. Lossless требует тарифа HiFi или Max.
A Tidal account is required. Sign in with a code on the Tidal website;
your password is entered only there. Lossless requires HiFi or Max.

Instagram и TikTok / Instagram and TikTok
-----------------------------------------
Видео скачиваются без водяного знака. Если сайт требует вход, выберите
браузер, где вы вошли в аккаунт: Настройки → «Instagram и TikTok» →
«Cookies браузера». Safari требует «Полный доступ к диску», Chrome может
запросить доступ к «Связке ключей».
Videos are downloaded without a watermark. If the site requires a sign-in,
choose the browser where you are logged in: Settings → “Instagram and TikTok”
→ “Browser cookies”. Safari requires Full Disk Access; Chrome may ask for
Keychain access.

Обновления / Updates
--------------------
LoadTube сам проверяет новые версии на GitHub Releases (не чаще раза в сутки).
Обновление необязательное: можно отложить или пропустить.
LoadTube checks GitHub Releases for updates (at most once a day).
Updates are optional: you can postpone or skip them.

Если YouTube перестанет скачиваться / If downloads stop working
---------------------------------------------------------------
Удалите папку с инструментами и перезапустите установку:
  rm -rf "$HOME/Library/Application Support/LoadTube/bin"

The app will offer to install the tools again on next launch.

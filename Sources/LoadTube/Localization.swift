import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case russian
    case english

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: return "language.system"
        case .russian: return "language.russian"
        case .english: return "language.english"
        }
    }
}

/// Простая встроенная локализация без .lproj — переключается на лету.
@MainActor
final class Localization: ObservableObject {
    static let shared = Localization()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: "language") ?? ""
        language = AppLanguage(rawValue: raw) ?? .russian
    }

    var effective: AppLanguage {
        if language != .system { return language }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("ru") ? .russian : .english
    }

    /// Безопасная подстановка без аргументов (символы % не интерпретируются).
    func t(_ key: String) -> String {
        let table = Self.tables[effective] ?? Self.tables[.english]!
        return table[key] ?? Self.tables[.english]?[key] ?? key
    }

    /// Строка с аргументами, например "осталось %@".
    func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }

    private static let tables: [AppLanguage: [String: String]] = [
        .russian: [
            "app.subtitle": "Видео и музыка с YouTube без лишних шагов",
            "app.checking": "Проверяем инструменты…",

            "input.placeholder": "Вставьте ссылку на видео, плейлист или трек…",
            "input.paste": "Вставить",
            "input.download": "Скачать",
            "input.folder.help": "Выбрать папку загрузок",
            "input.playlist": "Плейлист",
            "input.playlist.help": "Скачать весь плейлист, а не только одно видео",
            "input.spotify.hint": "Ссылка Spotify: найду этот трек на YouTube и скачаю лучший доступный звук.",

            "preset.maximum.title": "Максимум",
            "preset.maximum.subtitle": "Лучшее качество до 8K/HDR. Оригинальные кодеки, может не открыться в QuickTime.",
            "preset.4k.title": "4K MP4",
            "preset.4k.subtitle": "4K в MP4 (HEVC) — открывается в QuickTime. Иногда перекодируется.",
            "preset.1080.title": "1080p MP4",
            "preset.1080.subtitle": "Full HD H.264 — открывается везде, компактный размер.",
            "preset.mp3.title": "MP3",
            "preset.mp3.subtitle": "Только звук в лучшем качестве, с обложкой и тегами.",

            "downloads.title": "ЗАГРУЗКИ",
            "downloads.clear": "Очистить готовые",
            "downloads.openFolder": "Открыть папку",
            "downloads.empty.title": "Пока ничего не скачано",
            "downloads.empty.desc": "Вставьте ссылку, выберите качество и нажмите «Скачать»",

            "row.preparing": "Получение информации…",
            "row.queued": "В очереди",
            "row.merging": "Обработка…",
            "row.playlistSaved": "Плейлист сохранён",
            "row.done": "Готово",
            "row.cancelled": "Отменено",
            "row.eta": "осталось %@",
            "row.reveal": "Показать в Finder",
            "row.open": "Открыть файл",
            "row.retry": "Повторить",
            "row.cancel": "Отменить",

            "detail.fetching": "Получение информации…",
            "detail.playlist": "Плейлист · %d видео",
            "detail.merging": "Объединение видео и аудио…",
            "detail.mp3": "Конвертация в MP3…",
            "detail.converting": "Конвертация…",
            "detail.thumbnail": "Добавление обложки…",
            "detail.metadata": "Запись тегов…",
            "detail.transcoding": "Перекодирование в HEVC для QuickTime…",
            "detail.transcodingProgress": "Перекодирование в HEVC… %d%%",
            "detail.finished": "Готово",
            "detail.spotifyLookup": "Получение данных трека Spotify…",
            "detail.spotifySearching": "Поиск трека на YouTube…",
            "detail.tagsArtwork": "Обложка и теги…",
            "meta.video": "Видео",

            "warning.transcodeFailed": "Сохранено без перекодирования — кодек может не открыться в QuickTime.",

            "error.start": "Не удалось запустить yt-dlp: %@",
            "error.exit": "yt-dlp завершился с ошибкой (код %d).",
            "error.metadata": "Не удалось получить данные о видео.",
            "error.unknown": "Не удалось выполнить загрузку.",
            "error.spotifyOnlyTracks": "Поддерживаются только отдельные треки Spotify. Альбомы и плейлисты пока не скачиваются.",
            "error.spotifyLookup": "Не удалось получить данные трека из Spotify.",
            "error.spotifyNotFound": "Не удалось найти этот трек на YouTube.",
            "error.network": "Ошибка сети. Проверьте подключение и ссылку.",

            "install.title": "Почти готово",
            "install.desc": "Для загрузки видео LoadTube использует yt-dlp и ffmpeg. Установим их автоматически через Homebrew — это займёт пару минут.",
            "install.install": "Установить автоматически",
            "install.installing": "Устанавливаем инструменты…",
            "install.downloading": "Скачиваем инструменты…",
            "install.sizeHint": "Потребуется около 120 МБ. Homebrew не нужен.",
            "install.downloadFailed": "Не удалось скачать инструменты. Проверьте подключение и попробуйте снова.",
            "install.invalidBinary": "Скачанный файл не запускается на этом Mac.",
            "install.brewFallback": "Установить через Homebrew",
            "install.brewMissing": "Homebrew не найден. Установите его с brew.sh, затем нажмите «Проверить снова».",
            "install.checkAgain": "Проверить снова",
            "install.tryAgain": "Попробовать снова",
            "install.openBrew": "Открыть brew.sh",
            "install.copy": "Скопировать",
            "install.copied": "Скопировано",
            "install.brewFailed": "Не удалось установить инструменты. %@",
            "install.successLog": "✅ yt-dlp и ffmpeg установлены.",
            "install.homebrewMissingError": "Homebrew не найден. Установите его с brew.sh и нажмите «Проверить снова».",
            "install.brewUnknown": "Неизвестная ошибка Homebrew.",

            "settings.title": "Настройки",
            "settings.theme": "Тема оформления",
            "settings.language": "Язык интерфейса",
            "settings.folder": "Папка загрузок",
            "settings.folderDefault": "по умолчанию",
            "settings.change": "Изменить…",
            "settings.defaultQuality": "Качество по умолчанию",
            "settings.aboutHint": "Скачивание через yt-dlp и ffmpeg. Обновить yt-dlp: brew upgrade yt-dlp",
            "settings.done": "Готово",

            "notif.done": "Загрузка завершена",

            "language.system": "Системный",
            "language.russian": "Русский",
            "language.english": "English",

            "theme.system": "Системная",
            "theme.dark": "Тёмная",
            "theme.light": "Светлая",

            "speed.suffix": "/с"
        ],
        .english: [
            "app.subtitle": "Video and music from YouTube, simplified",
            "app.checking": "Checking tools…",

            "input.placeholder": "Paste a video, playlist, or track link…",
            "input.paste": "Paste",
            "input.download": "Download",
            "input.folder.help": "Choose download folder",
            "input.playlist": "Playlist",
            "input.playlist.help": "Download the whole playlist instead of one video",
            "input.spotify.hint": "Spotify link: I'll find this track on YouTube and download the best available audio.",

            "preset.maximum.title": "Maximum",
            "preset.maximum.subtitle": "Best quality up to 8K/HDR. Original codecs, may not play in QuickTime.",
            "preset.4k.title": "4K MP4",
            "preset.4k.subtitle": "4K MP4 (HEVC) — plays in QuickTime. Transcodes when needed.",
            "preset.1080.title": "1080p MP4",
            "preset.1080.subtitle": "Full HD H.264 — plays everywhere, compact size.",
            "preset.mp3.title": "MP3",
            "preset.mp3.subtitle": "Audio only in the best quality, with cover art and tags.",

            "downloads.title": "DOWNLOADS",
            "downloads.clear": "Clear finished",
            "downloads.openFolder": "Open folder",
            "downloads.empty.title": "Nothing downloaded yet",
            "downloads.empty.desc": "Paste a link, choose quality, and press Download",

            "row.preparing": "Fetching info…",
            "row.queued": "Queued",
            "row.merging": "Processing…",
            "row.playlistSaved": "Playlist saved",
            "row.done": "Done",
            "row.cancelled": "Cancelled",
            "row.eta": "%@ left",
            "row.reveal": "Show in Finder",
            "row.open": "Open file",
            "row.retry": "Retry",
            "row.cancel": "Cancel",

            "detail.fetching": "Fetching info…",
            "detail.playlist": "Playlist · %d videos",
            "detail.merging": "Merging video and audio…",
            "detail.mp3": "Converting to MP3…",
            "detail.converting": "Converting…",
            "detail.thumbnail": "Adding cover art…",
            "detail.metadata": "Writing tags…",
            "detail.transcoding": "Transcoding to HEVC for QuickTime…",
            "detail.transcodingProgress": "Transcoding to HEVC… %d%%",
            "detail.finished": "Done",
            "detail.spotifyLookup": "Resolving Spotify track…",
            "detail.spotifySearching": "Searching YouTube…",
            "detail.tagsArtwork": "Cover art and tags…",
            "meta.video": "Video",

            "warning.transcodeFailed": "Saved without transcoding — the codec may not play in QuickTime.",

            "error.start": "Could not launch yt-dlp: %@",
            "error.exit": "yt-dlp exited with an error (code %d).",
            "error.metadata": "Could not fetch video details.",
            "error.unknown": "Download failed.",
            "error.spotifyOnlyTracks": "Only individual Spotify tracks are supported. Albums and playlists aren't supported yet.",
            "error.spotifyLookup": "Could not fetch track details from Spotify.",
            "error.spotifyNotFound": "Could not find this track on YouTube.",
            "error.network": "Network error. Check your connection and the link.",

            "install.title": "Almost ready",
            "install.desc": "LoadTube uses yt-dlp and ffmpeg to download media. Let's install them via Homebrew — it takes a minute.",
            "install.install": "Install automatically",
            "install.installing": "Installing tools…",
            "install.downloading": "Downloading tools…",
            "install.sizeHint": "About 120 MB will be downloaded. No Homebrew required.",
            "install.downloadFailed": "Could not download the tools. Check your connection and try again.",
            "install.invalidBinary": "The downloaded file can't run on this Mac.",
            "install.brewFallback": "Install via Homebrew",
            "install.brewMissing": "Homebrew not found. Install it from brew.sh, then press Check again.",
            "install.checkAgain": "Check again",
            "install.tryAgain": "Try again",
            "install.openBrew": "Open brew.sh",
            "install.copy": "Copy",
            "install.copied": "Copied",
            "install.brewFailed": "Could not install the tools. %@",
            "install.successLog": "✅ yt-dlp and ffmpeg installed.",
            "install.homebrewMissingError": "Homebrew not found. Install it from brew.sh and press Check again.",
            "install.brewUnknown": "Unknown Homebrew error.",

            "settings.title": "Settings",
            "settings.theme": "Appearance",
            "settings.language": "Language",
            "settings.folder": "Download folder",
            "settings.folderDefault": "default",
            "settings.change": "Change…",
            "settings.defaultQuality": "Default quality",
            "settings.aboutHint": "Powered by yt-dlp and ffmpeg. Update yt-dlp: brew upgrade yt-dlp",
            "settings.done": "Done",

            "notif.done": "Download complete",

            "language.system": "System",
            "language.russian": "Russian",
            "language.english": "English",

            "theme.system": "System",
            "theme.dark": "Dark",
            "theme.light": "Light",

            "speed.suffix": "/s"
        ]
    ]
}

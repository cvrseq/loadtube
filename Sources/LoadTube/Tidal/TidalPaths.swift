import Foundation

enum TidalPathBuilder {
    static func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?*\"<>|\n\r\t")
        var clean = value.components(separatedBy: forbidden).joined(separator: " ")
        while clean.contains("  ") {
            clean = clean.replacingOccurrences(of: "  ", with: " ")
        }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count > 120 {
            clean = String(clean.prefix(120)).trimmingCharacters(in: .whitespaces)
        }
        return clean.isEmpty ? "Unknown" : clean
    }

    static func albumFolder(
        _ album: TidalAlbum?,
        fallbackArtist: String,
        root: URL
    ) -> URL {
        let artist = sanitize(album?.artistsDisplay.isEmpty == false
            ? (album?.artistsDisplay ?? fallbackArtist)
            : fallbackArtist)
        let title = sanitize(album?.displayTitle ?? "Unknown Album")
        let year = album?.year ?? ""
        let folderName = year.isEmpty ? title : "\(title) (\(year))"
        return root
            .appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    static func trackURL(
        track: TidalTrack,
        album: TidalAlbum?,
        playlist: TidalPlaylist?,
        mixTitle: String?,
        root: URL,
        fileExtension: String,
        style: TidalFolderStyle,
        isSingle: Bool,
        position: Int?
    ) -> URL {
        let artist = sanitize(track.artistsDisplay.isEmpty
            ? (album?.artistsDisplay ?? "Unknown Artist")
            : track.artistsDisplay)
        let explicit = track.explicit == true ? " (Explicit)" : ""
        let title = sanitize(track.displayTitle + explicit)
        let number = max(position ?? track.trackNumber ?? 0, 0)
        let prefix = String(format: "%02d", number)

        var directory = root
        var filename: String

        if isSingle || style == .flat {
            filename = "\(artist) - \(title)"
        } else if let playlist {
            directory = root.appendingPathComponent(sanitize(playlist.displayTitle), isDirectory: true)
            filename = "\(prefix) - \(artist) - \(title)"
        } else if let mixTitle {
            directory = root.appendingPathComponent(sanitize(mixTitle), isDirectory: true)
            filename = "\(prefix) - \(artist) - \(title)"
        } else if let album {
            directory = albumFolder(album, fallbackArtist: artist, root: root)
            if (album.numberOfVolumes ?? 1) > 1, let volume = track.volumeNumber {
                directory = directory.appendingPathComponent("CD\(volume)", isDirectory: true)
            }
            filename = "\(prefix) - \(title)"
        } else {
            filename = "\(artist) - \(title)"
        }

        return directory.appendingPathComponent("\(filename).\(fileExtension)")
    }

    static func videoURL(
        video: TidalVideo,
        album: TidalAlbum?,
        playlist: TidalPlaylist?,
        mixTitle: String?,
        root: URL,
        style: TidalFolderStyle,
        isSingle: Bool,
        position: Int?
    ) -> URL {
        let artist = sanitize(video.artistsDisplay.isEmpty
            ? (album?.artistsDisplay ?? "Unknown Artist")
            : video.artistsDisplay)
        let explicit = video.explicit == true ? " (Explicit)" : ""
        let title = sanitize(video.displayTitle + explicit)
        let number = max(position ?? video.trackNumber ?? 0, 0)
        let prefix = String(format: "%02d", number)

        var directory = root
        var filename: String

        if isSingle || style == .flat {
            filename = "\(artist) - \(title)"
        } else if let playlist {
            directory = root.appendingPathComponent(sanitize(playlist.displayTitle), isDirectory: true)
            filename = "\(prefix) - \(artist) - \(title)"
        } else if let mixTitle {
            directory = root.appendingPathComponent(sanitize(mixTitle), isDirectory: true)
            filename = "\(prefix) - \(artist) - \(title)"
        } else if let album {
            directory = albumFolder(album, fallbackArtist: artist, root: root)
            filename = "\(prefix) - \(title)"
        } else {
            filename = "\(artist) - \(title)"
        }

        return directory.appendingPathComponent("\(filename).mp4")
    }

    static func coverFile(in directory: URL) -> URL {
        directory.appendingPathComponent("cover.jpg")
    }

    static func lyricsFile(for file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("lrc")
    }
}

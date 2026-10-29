import Foundation

/// Разобранный поток Tidal.
enum TidalStream {
    /// Один файл (BTS). `urls` может содержать зеркала.
    case file(urls: [URL], codec: String, encryptionKey: String?)
    /// DASH: init-сегмент + media-сегменты.
    case segments(urls: [URL], codec: String)
    /// HLS-плейлист (видео).
    case hls(url: URL)

    var codec: String {
        switch self {
        case .file(_, let codec, _): return codec
        case .segments(_, let codec): return codec
        case .hls: return "h264"
        }
    }

    var fileExtension: String {
        let value = codec.lowercased()
        if value.contains("flac") { return "flac" }
        if value.contains("alac") || value.contains("m4a") { return "m4a" }
        if value.contains("ac4") || value.contains("mha1") { return "mp4" }
        if value.contains("mp4a") || value.contains("aac") { return "m4a" }
        if value.contains("mp4") { return "m4a" }
        if value.contains("h264") || value.contains("avc") || value.contains("hevc") { return "mp4" }
        return "flac"
    }

    var isLossless: Bool {
        let value = codec.lowercased()
        return value.contains("flac") || value.contains("alac")
    }
}

struct TidalHLSVariant {
    let height: Int
    let bandwidth: Int
    let url: URL
}

enum TidalManifestParser {
    static func parse(
        mimeType: String,
        manifest: String,
        quality: String?
    ) throws -> TidalStream {
        guard let data = decodeBase64(manifest) else {
            throw TidalError.manifestUnsupported
        }

        if mimeType.contains("vnd.tidal.bts") || mimeType.contains("vnd.tidal.emu") {
            return try parseBTS(data: data)
        }
        if mimeType.contains("dash+xml") {
            return try parseDASH(data: data)
        }
        throw TidalError.manifestUnsupported
    }

    private static func decodeBase64(_ text: String) -> Data? {
        var value = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
    }

    private static func parseBTS(data: Data) throws -> TidalStream {
        guard let message = try? JSONDecoder().decode(TidalBSMessage.self, from: data) else {
            throw TidalError.manifestUnsupported
        }
        guard let rawURLs = message.urls, !rawURLs.isEmpty else {
            throw TidalError.manifestUnsupported
        }
        let urls = rawURLs.compactMap { URL(string: $0) }
        guard !urls.isEmpty else { throw TidalError.manifestUnsupported }

        let codec = message.codecs ?? message.mimeType ?? ""
        if urls.count == 1, urls[0].pathExtension.lowercased() == "m3u8" {
            return .hls(url: urls[0])
        }
        return .file(
            urls: urls,
            codec: codec,
            encryptionKey: message.keyId ?? message.encryptionKey
        )
    }

    // MARK: - DASH

    private static func parseDASH(data: Data) throws -> TidalStream {
        let delegate = DASHParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let representation = delegate.bestAudioRepresentation else {
            throw TidalError.manifestUnsupported
        }

        let urls = buildSegmentURLs(representation)
        guard !urls.isEmpty else { throw TidalError.manifestUnsupported }
        return .segments(urls: urls, codec: representation.codecs)
    }

    private static func buildSegmentURLs(_ rep: DASHRepresentation) -> [URL] {
        var result: [URL] = []
        let base = rep.baseURL.isEmpty ? rep.globalBaseURL : rep.baseURL

        func resolve(_ value: String) -> URL? {
            if value.hasPrefix("http://") || value.hasPrefix("https://") {
                return URL(string: value)
            }
            if value.hasPrefix("//") {
                return URL(string: "https:" + value)
            }
            if value.hasPrefix("/") {
                return URL(string: "https://api.tidal.com" + value)
            }
            if !base.isEmpty {
                return URL(string: value, relativeTo: URL(string: base))?.absoluteURL
            }
            return URL(string: value)
        }

        func replace(_ template: String, number: Int, time: Int64) -> String {
            var value = template
            value = value.replacingOccurrences(of: "$RepresentationID$", with: rep.id)
            value = value.replacingOccurrences(of: "$Bandwidth$", with: String(rep.bandwidth))
            value = value.replacingOccurrences(of: "$Number$", with: String(number))
            value = value.replacingOccurrences(of: "$Time$", with: String(time))
            // Формат вида $Number%05d$ не критичен для Tidal, но обработаем простой случай.
            if let regex = try? NSRegularExpression(pattern: "\\$Number%0(\\d+)d\\$") {
                let range = NSRange(value.startIndex..., in: value)
                if let match = regex.firstMatch(in: value, range: range),
                   let digitsRange = Range(match.range(at: 1), in: value),
                   let digits = Int(value[digitsRange]) {
                    let formatted = String(format: "%0\(digits)d", number)
                    value = regex.stringByReplacingMatches(
                        in: value,
                        range: range,
                        withTemplate: formatted
                    )
                }
            }
            return value
        }

        if !rep.initialization.isEmpty {
            let initURL = replace(rep.initialization, number: rep.startNumber, time: rep.timeline.first?.time ?? 0)
            if let url = resolve(initURL) { result.append(url) }
        }

        if !rep.timeline.isEmpty {
            var number = rep.startNumber
            for entry in rep.timeline {
                let repeatCount = max(entry.repeatCount, 0) + 1
                for _ in 0..<repeatCount {
                    let value = replace(rep.media, number: number, time: entry.time)
                    if let url = resolve(value) { result.append(url) }
                    number += 1
                }
            }
        } else if !rep.media.isEmpty, rep.segmentDuration > 0, rep.presentationDuration > 0 {
            let count = max(Int(ceil(Double(rep.presentationDuration) / Double(rep.segmentDuration))), 1)
            for index in 0..<count {
                let number = rep.startNumber + index
                let time = Int64(index * rep.segmentDuration)
                let value = replace(rep.media, number: number, time: time)
                if let url = resolve(value) { result.append(url) }
            }
        }

        return result
    }
}

struct DASHTimelineEntry {
    let time: Int64
    let duration: Int64
    let repeatCount: Int
}

struct DASHRepresentation {
    var id = ""
    var bandwidth = 0
    var codecs = ""
    var mimeType = ""
    var baseURL = ""
    var globalBaseURL = ""
    var initialization = ""
    var media = ""
    var startNumber = 1
    var segmentDuration = 0
    var presentationDuration = 0
    var timeline: [DASHTimelineEntry] = []

    var isAudio: Bool {
        let mime = mimeType.lowercased()
        let codec = codecs.lowercased()
        return mime.hasPrefix("audio/")
            || codec.contains("flac")
            || codec.contains("mp4a")
            || codec.contains("aac")
            || codec.contains("ac-3")
            || codec.contains("ec-3")
    }

    var isLossless: Bool {
        codecs.lowercased().contains("flac")
    }
}

private final class DASHParserDelegate: NSObject, XMLParserDelegate {
    var representations: [DASHRepresentation] = []
    var globalBaseURL = ""

    private var currentRep: DASHRepresentation?
    private var currentText = ""
    private var inBaseURL = false
    private var inTimeline = false
    private var adaptationTemplate: [String: String] = [:]
    private var adaptationTimeline: [DASHTimelineEntry] = []
    private var adaptationContentType = ""
    private var adaptationBaseURL = ""
    private var adaptationPresentationDuration = 0

    var bestAudioRepresentation: DASHRepresentation? {
        let audio = representations.filter(\.isAudio)
        guard !audio.isEmpty else { return nil }
        return audio.max { lhs, rhs in
            if lhs.isLossless != rhs.isLossless { return !lhs.isLossless }
            return lhs.bandwidth < rhs.bandwidth
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""

        switch elementName {
        case "BaseURL":
            inBaseURL = true
        case "AdaptationSet":
            adaptationTemplate = [:]
            adaptationTimeline = []
            adaptationContentType = attributeDict["contentType"]?.lowercased() ?? ""
            adaptationBaseURL = ""
            if let duration = attributeDict["duration"], let value = Self.parseISODuration(duration) {
                adaptationPresentationDuration = value
            }
        case "Representation":
            var rep = DASHRepresentation()
            rep.id = attributeDict["id"] ?? ""
            rep.bandwidth = Int(attributeDict["bandwidth"] ?? "") ?? 0
            rep.codecs = attributeDict["codecs"] ?? ""
            rep.mimeType = attributeDict["mimeType"] ?? ""
            rep.globalBaseURL = adaptationBaseURL.isEmpty ? globalBaseURL : adaptationBaseURL
            rep.presentationDuration = adaptationPresentationDuration
            currentRep = rep
        case "SegmentTemplate":
            if var rep = currentRep {
                rep.initialization = attributeDict["initialization"] ?? rep.initialization
                rep.media = attributeDict["media"] ?? rep.media
                rep.startNumber = Int(attributeDict["startNumber"] ?? "") ?? rep.startNumber
                rep.segmentDuration = Int(attributeDict["duration"] ?? "") ?? rep.segmentDuration
                currentRep = rep
            }
            // SegmentTemplate часто лежит на уровне AdaptationSet и наследуется
            // всеми Representation.
            if attributeDict["initialization"] != nil || attributeDict["media"] != nil {
                adaptationTemplate = attributeDict
            }
        case "SegmentTimeline":
            inTimeline = true
        case "S":
            guard inTimeline else { break }
            if var rep = currentRep {
                let previousEnd = rep.timeline.last.map {
                    $0.time + $0.duration * Int64($0.repeatCount + 1)
                } ?? 0
                let time = Int64(attributeDict["t"] ?? "") ?? previousEnd
                let duration = Int64(attributeDict["d"] ?? "") ?? 0
                let repeatCount = Int(attributeDict["r"] ?? "") ?? 0
                rep.timeline.append(DASHTimelineEntry(time: time, duration: duration, repeatCount: repeatCount))
                currentRep = rep
            } else {
                let previousEnd = adaptationTimeline.last.map {
                    $0.time + $0.duration * Int64($0.repeatCount + 1)
                } ?? 0
                let time = Int64(attributeDict["t"] ?? "") ?? previousEnd
                let duration = Int64(attributeDict["d"] ?? "") ?? 0
                let repeatCount = Int(attributeDict["r"] ?? "") ?? 0
                adaptationTimeline.append(DASHTimelineEntry(time: time, duration: duration, repeatCount: repeatCount))
            }
        case "MPD":
            if let duration = attributeDict["mediaPresentationDuration"],
               let value = Self.parseISODuration(duration) {
                adaptationPresentationDuration = value
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "BaseURL":
            let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if var rep = currentRep {
                rep.baseURL = value
                currentRep = rep
            } else if !value.isEmpty {
                if globalBaseURL.isEmpty {
                    globalBaseURL = value
                } else {
                    adaptationBaseURL = value
                }
            }
            inBaseURL = false
        case "Representation":
            if let rep = currentRep {
                var final = rep
                if final.initialization.isEmpty, let initValue = adaptationTemplate["initialization"] {
                    final.initialization = initValue
                }
                if final.media.isEmpty, let mediaValue = adaptationTemplate["media"] {
                    final.media = mediaValue
                }
                if final.startNumber == 1, let start = adaptationTemplate["startNumber"], let value = Int(start) {
                    final.startNumber = value
                }
                if final.segmentDuration == 0, let duration = adaptationTemplate["duration"], let value = Int(duration) {
                    final.segmentDuration = value
                }
                if final.timeline.isEmpty, !adaptationTimeline.isEmpty {
                    final.timeline = adaptationTimeline
                }
                if adaptationContentType == "audio" || final.isAudio {
                    representations.append(final)
                }
            }
            currentRep = nil
        case "SegmentTimeline":
            inTimeline = false
        case "AdaptationSet":
            adaptationTemplate = [:]
            adaptationTimeline = []
            adaptationContentType = ""
            adaptationBaseURL = ""
        default:
            break
        }
        currentText = ""
    }

    private static func parseISODuration(_ value: String) -> Int? {
        guard value.hasPrefix("PT") else { return nil }
        var seconds = 0.0
        var number = ""
        for character in value.dropFirst(2) {
            if character.isNumber || character == "." {
                number.append(character)
            } else {
                guard let amount = Double(number) else { number = ""; continue }
                switch character {
                case "H": seconds += amount * 3600
                case "M": seconds += amount * 60
                case "S": seconds += amount
                default: break
                }
                number = ""
            }
        }
        return seconds > 0 ? Int(seconds.rounded()) : nil
    }
}

// MARK: - HLS

enum TidalHLS {
    static func variants(from text: String, baseURL: URL) -> [TidalHLSVariant] {
        var result: [TidalHLSVariant] = []
        var pendingHeight: Int?
        var pendingBandwidth = 0

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = line.replacingOccurrences(of: "#EXT-X-STREAM-INF:", with: "")
                pendingBandwidth = Int(attributeValue("BANDWIDTH", in: attributes) ?? "") ?? 0
                if let resolution = attributeValue("RESOLUTION", in: attributes),
                   let height = resolution.split(separator: "x").last {
                    pendingHeight = Int(height)
                }
            } else if !line.isEmpty, !line.hasPrefix("#"), pendingHeight != nil {
                if let url = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                    result.append(TidalHLSVariant(
                        height: pendingHeight ?? 0,
                        bandwidth: pendingBandwidth,
                        url: url
                    ))
                }
                pendingHeight = nil
                pendingBandwidth = 0
            }
        }
        return result
    }

    static func bestVariant(
        from variants: [TidalHLSVariant],
        maxHeight: Int
    ) -> TidalHLSVariant? {
        let fitting = variants.filter { $0.height <= maxHeight && $0.height > 0 }
        if let best = fitting.max(by: { $0.height < $1.height }) {
            return best
        }
        return variants.min(by: { $0.height < $1.height })
    }

    private static func attributeValue(_ name: String, in text: String) -> String? {
        guard let range = text.range(of: name + "=") else { return nil }
        let rest = text[range.upperBound...]
        if rest.hasPrefix("\"") {
            let withoutQuote = rest.dropFirst()
            guard let end = withoutQuote.firstIndex(of: "\"") else { return nil }
            return String(withoutQuote[..<end])
        }
        return rest.split(separator: ",").first.map(String.init)
    }
}

import Foundation

enum VideoProvider: String, Codable, Sendable, Hashable, CaseIterable {
    case youtube, vimeo, other
}

/// Referência a mídia de um exercício (SPEC §3.3). Arquivos locais são nomes relativos a
/// `Application Support/Media` (resolvidos pelo serviço de mídia, não aqui).
enum MediaRef: Codable, Sendable, Hashable {
    case image(fileName: String)
    case localVideo(fileName: String, thumbnailFileName: String?)
    case externalVideo(url: URL, provider: VideoProvider, videoID: String?)

    /// Cria a referência a partir de um link colado pelo usuário (YouTube/Vimeo detectados).
    static func externalVideo(link: String) -> MediaRef? {
        guard let video = VideoLinkParser.parse(link) else { return nil }
        return .externalVideo(url: video.url, provider: video.provider, videoID: video.videoID)
    }
}

/// Resultado do reconhecimento de um link de vídeo.
struct ExternalVideo: Sendable, Hashable {
    var provider: VideoProvider
    /// ID do vídeo (YouTube: 11 caracteres; Vimeo: numérico). `nil` para `.other`.
    var videoID: String?
    /// URL original (normalizada com esquema https quando faltava).
    var url: URL

    /// URL do player oficial para `WKWebView`.
    var embedURL: URL? {
        guard let videoID else { return nil }
        switch provider {
        case .youtube: return URL(string: "https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1")
        case .vimeo: return URL(string: "https://player.vimeo.com/video/\(videoID)?playsinline=1")
        case .other: return nil
        }
    }

    /// Link "abrir no app/site" (fallback do embed, SPEC R3).
    var watchURL: URL {
        guard let videoID else { return url }
        switch provider {
        case .youtube: return URL(string: "https://www.youtube.com/watch?v=\(videoID)") ?? url
        case .vimeo: return URL(string: "https://vimeo.com/\(videoID)") ?? url
        case .other: return url
        }
    }

    /// Miniatura sem rede extra (só YouTube tem URL determinística; Vimeo exige oEmbed).
    var thumbnailURL: URL? {
        guard provider == .youtube, let videoID else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
    }
}

/// Reconhece links de YouTube e Vimeo. Qualquer outra URL http(s) válida vira `.other`.
enum VideoLinkParser {
    static func parse(_ text: String) -> ExternalVideo? {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(" ") else { return nil }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }
        guard let url = URL(string: raw) else { return nil }
        return parse(url)
    }

    static func parse(_ url: URL) -> ExternalVideo? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host()?.lowercased(), host.contains(".") else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let components = url.pathComponents.filter { $0 != "/" }

        if let id = youtubeID(host: host, components: components, url: url) {
            return ExternalVideo(provider: .youtube, videoID: id, url: url)
        }
        if let id = vimeoID(host: host, components: components) {
            return ExternalVideo(provider: .vimeo, videoID: id, url: url)
        }
        return ExternalVideo(provider: .other, videoID: nil, url: url)
    }

    private static let youtubeHosts: Set<String> = [
        "youtube.com", "m.youtube.com", "music.youtube.com", "youtube-nocookie.com",
    ]

    private static func youtubeID(host: String, components: [String], url: URL) -> String? {
        if host == "youtu.be" {
            return components.first.flatMap(validYouTubeID)
        }
        guard youtubeHosts.contains(host) else { return nil }
        if components.first == "watch" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            return query?.first(where: { $0.name == "v" })?.value.flatMap(validYouTubeID)
        }
        if components.count >= 2, ["shorts", "embed", "live", "v"].contains(components[0]) {
            return validYouTubeID(components[1])
        }
        return nil
    }

    private static func validYouTubeID(_ candidate: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard candidate.count == 11, candidate.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return candidate
    }

    private static func vimeoID(host: String, components: [String]) -> String? {
        if host == "player.vimeo.com" {
            guard components.count >= 2, components[0] == "video" else { return nil }
            return numeric(components[1])
        }
        guard host == "vimeo.com" else { return nil }
        // Com segmento video/videos, o vídeo é o numérico seguinte:
        // vimeo.com/groups/x/videos/123, vimeo.com/showcase/9/video/123, vimeo.com/album/9/video/123.
        if let index = components.firstIndex(where: { $0 == "video" || $0 == "videos" }) {
            return components.indices.contains(index + 1) ? numeric(components[index + 1]) : nil
        }
        // Senão, só vimeo.com/123, vimeo.com/123/<hash> e vimeo.com/channels/<nome>/123.
        // showcase/album/groups sem "video" apontam para coleções, não vídeos.
        switch components.count {
        case 1, 2: return numeric(components[0])
        case 3 where components[0] == "channels": return numeric(components[2])
        default: return nil
        }
    }

    private static func numeric(_ candidate: String) -> String? {
        guard !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return candidate
    }
}

import Foundation

/// URLs de embed e política de navegação do `WKWebView` (lógica pura, testável).
///
/// O ID vindo do dado persistido é revalidado antes de virar URL: nada de interpolar string não validada.
enum EmbedPolicy {
    /// Hosts (e subdomínios) que o iframe do player pode carregar. Só o necessário para YouTube (nocookie)
    /// e Vimeo; qualquer outro destino é cancelado.
    static let allowedHosts = ["youtube-nocookie.com", "youtube.com", "player.vimeo.com", "vimeo.com"]

    static func validYouTubeID(_ id: String) -> Bool {
        id.count == 11 && id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 95 || $0 == 45 }
    }

    static func validVimeoID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 12 && id.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    /// URL de embed oficial reconstruída de provedor + ID revalidado; `nil` se o ID for inválido ou o provedor não tiver embed.
    static func embedURL(provider: VideoProvider, videoID: String?) -> URL? {
        guard let videoID else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.queryItems = [URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "autoplay", value: "0")]
        switch provider {
        case .youtube:
            guard validYouTubeID(videoID) else { return nil }
            components.host = "www.youtube-nocookie.com"
            components.path = "/embed/\(videoID)"
        case .vimeo:
            guard validVimeoID(videoID) else { return nil }
            components.host = "player.vimeo.com"
            components.path = "/video/\(videoID)"
            components.queryItems = [URLQueryItem(name: "playsinline", value: "1"), URLQueryItem(name: "autoplay", value: "0")]
        case .other:
            return nil
        }
        return components.url
    }

    /// Link "abrir no app/site": reconstruído do ID quando válido; senão a URL guardada, só se for http(s).
    static func watchURL(provider: VideoProvider, videoID: String?, stored: URL) -> URL? {
        if let videoID {
            switch provider {
            case .youtube where validYouTubeID(videoID): return URL(string: "https://www.youtube.com/watch?v=\(videoID)")
            case .vimeo where validVimeoID(videoID): return URL(string: "https://vimeo.com/\(videoID)")
            default: break
            }
        }
        guard let scheme = stored.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return stored
    }

    static func isAllowed(host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Decide se o `WKWebView` pode seguir uma navegação.
    /// - Quadro principal: só a carga inicial (`about:` ou o `baseURL` do HTML local); nada de ir para outro site.
    /// - Subquadros (iframe): só https em hosts da allowlist, ou `about:`.
    /// - Janela nova (`targetIsNil`): sempre cancelada.
    static func allowsNavigation(to url: URL?, isMainFrame: Bool, targetIsNil: Bool = false, baseURL: URL?) -> Bool {
        guard !targetIsNil, let url else { return false }
        let scheme = url.scheme?.lowercased()
        if scheme == "about" { return true }
        if isMainFrame { return baseURL != nil && url == baseURL }
        return scheme == "https" && isAllowed(host: url.host())
    }

    /// HTML local com o iframe sandboxed do embed.
    static func html(embedURL: URL) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="\(embedURL.absoluteString)" sandbox="allow-scripts allow-same-origin allow-presentation" allow="encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
    }
}

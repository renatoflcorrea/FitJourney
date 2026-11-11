import AVKit
import SwiftUI
import WebKit

// MARK: - Descrições e rótulos

extension MediaRef {
    /// Texto para VoiceOver ("Foto 2 de 3"). Cada caso tem a própria string localizável.
    func accessibilityLabel(index: Int? = nil, of total: Int? = nil) -> String {
        if let index, let total, total > 1 {
            let position = index + 1
            switch self {
            case .image: return String(localized: "Foto \(position) de \(total)")
            case .localVideo: return String(localized: "Vídeo \(position) de \(total)")
            case .externalVideo(_, let provider, _):
                switch provider {
                case .youtube: return String(localized: "Vídeo do YouTube \(position) de \(total)")
                case .vimeo: return String(localized: "Vídeo do Vimeo \(position) de \(total)")
                case .other: return String(localized: "Link de vídeo \(position) de \(total)")
                }
            }
        }
        switch self {
        case .image: return String(localized: "Foto")
        case .localVideo: return String(localized: "Vídeo")
        case .externalVideo(_, let provider, _):
            switch provider {
            case .youtube: return String(localized: "Vídeo do YouTube")
            case .vimeo: return String(localized: "Vídeo do Vimeo")
            case .other: return String(localized: "Link de vídeo")
            }
        }
    }

    var providerName: String? {
        guard case .externalVideo(_, let provider, _) = self else { return nil }
        switch provider {
        case .youtube: return "YouTube"
        case .vimeo: return "Vimeo"
        case .other: return nil
        }
    }

    var isVideo: Bool {
        if case .image = self { false } else { true }
    }
}

// MARK: - Miniatura

/// Miniatura de uma mídia (foto, vídeo da galeria ou link). Preenche o espaço dado e corta o excesso.
/// Por privacidade, listas não buscam a miniatura remota do YouTube (`allowsRemoteThumbnail: false`,
/// o padrão): mostram um ícone do provedor. Detalhe e editor liberam a busca (com cache).
struct MediaThumbnailView: View {
    let media: MediaRef
    /// Maior lado a decodificar (px).
    var maxPixel: Int = 400
    /// Mostra o símbolo de play sobre vídeos.
    var showsPlayBadge = true
    var allowsRemoteThumbnail = false

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            FJColor.fill
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
            if showsPlayBadge, media.isVideo {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(FJColor.onFill)
                    .padding(FJSpacing.m)
                    .background(.black.opacity(0.45), in: Circle())
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .task(id: TaskKey(media: media, remote: allowsRemoteThumbnail)) { await load() }
    }

    private struct TaskKey: Hashable {
        let media: MediaRef
        let remote: Bool
    }

    private var placeholder: some View {
        Image(systemName: placeholderSymbol)
            .font(.title2)
            .foregroundStyle(FJColor.textSecondary)
            .accessibilityHidden(true)
    }

    private var placeholderSymbol: String {
        switch media {
        case .image: "photo"
        case .localVideo: "video"
        case .externalVideo(_, let provider, _): provider == .other ? "safari" : "play.rectangle"
        }
    }

    private func load() async {
        image = nil
        switch media {
        case .image(let fileName):
            image = await MediaImageLoader.shared.image(for: fileName, maxPixel: maxPixel)
        case .localVideo(_, let thumb):
            if let thumb { image = await MediaImageLoader.shared.image(for: thumb, maxPixel: maxPixel) }
        case .externalVideo(let url, let provider, let id):
            guard allowsRemoteThumbnail, provider == .youtube, let id, EmbedPolicy.validYouTubeID(id),
                  let thumbURL = ExternalVideo(provider: provider, videoID: id, url: url).thumbnailURL else { return }
            image = await MediaImageLoader.shared.remoteImage(from: thumbURL)
        }
    }
}

// MARK: - Player

/// Player de uma mídia do exercício. Imagem: tela cheia com zoom; vídeo local: `VideoPlayer`;
/// YouTube/Vimeo: embed oficial em `WKWebView` (sem autoplay) com "Abrir no YouTube/Vimeo" como saída;
/// outras URLs: abrir no Safari. Apresente dentro de `fullScreenCover`/`sheet` (a view não traz botão de fechar).
struct ExerciseMediaView: View {
    let media: MediaRef

    var body: some View {
        Group {
            switch media {
            case .image(let fileName):
                ZoomableLocalImage(fileName: fileName)
            case .localVideo(let fileName, _):
                LocalVideoPlayer(fileName: fileName)
            case .externalVideo(let url, let provider, let id):
                ExternalVideoPlayer(video: ExternalVideo(provider: provider, videoID: id, url: url))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FJColor.background.ignoresSafeArea())
    }
}

// MARK: Imagem com zoom

private struct ZoomableLocalImage: View {
    let fileName: String

    @State private var image: CGImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(zoom)
                    .simultaneousGesture(pan)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .accessibilityLabel("Foto do exercício")
                    .accessibilityHint("Toque duas vezes para ampliar")
                    .accessibilityAddTraits(.isImage)
                    .accessibilityZoomAction { action in
                        withAnimation(FJMotion.value) {
                            switch action.direction {
                            case .zoomIn: setScale(scale + 1)
                            case .zoomOut: setScale(scale - 1)
                            }
                        }
                    }
            } else if failed {
                FJEmptyState("Foto indisponível", systemImage: "photo.badge.exclamationmark",
                             message: "O arquivo não foi encontrado neste aparelho.")
            } else {
                FJLoadingState()
            }
        }
        .task {
            image = await MediaImageLoader.shared.image(for: fileName, maxPixel: 2048)
            failed = image == nil
        }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { scale = (committedScale * $0.magnification).fjClamped(to: 1...5) }
            .onEnded { _ in
                committedScale = scale
                if scale <= 1 { reset() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { if scale > 1 { offset = CGSize(width: committedOffset.width + $0.translation.width, height: committedOffset.height + $0.translation.height) } }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom() {
        withAnimation(FJMotion.value) { scale > 1 ? reset() : setScale(2.5) }
    }

    private func setScale(_ value: CGFloat) {
        let clamped = value.fjClamped(to: 1...5)
        if clamped <= 1 { reset() } else { scale = clamped; committedScale = clamped }
    }

    private func reset() {
        scale = 1; committedScale = 1; offset = .zero; committedOffset = .zero
    }
}

// MARK: Vídeo local

private struct LocalVideoPlayer: View {
    let fileName: String
    @State private var player: AVPlayer?
    @State private var previousCategory: AVAudioSession.Category?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel("Vídeo do exercício")
            } else {
                FJEmptyState("Vídeo indisponível", systemImage: "video.slash",
                             message: "O arquivo não foi encontrado neste aparelho.")
            }
        }
        .task {
            if let url = MediaStore.shared.url(for: fileName), FileManager.default.fileExists(atPath: url.path()) {
                player = AVPlayer(url: url)
            }
        }
        .onAppear { beginPlayback() }
        .onDisappear {
            player?.pause()
            endPlayback()
        }
    }

    /// `.playback`: o vídeo toca com o som mesmo com a chave de silêncio ligada.
    private func beginPlayback() {
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func endPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousCategory { try? session.setCategory(previousCategory) }
    }
}

// MARK: YouTube / Vimeo / outros

private struct ExternalVideoPlayer: View {
    let video: ExternalVideo

    @Environment(\.openURL) private var openURL
    @State private var embedFailed = false

    private var embedURL: URL? { EmbedPolicy.embedURL(provider: video.provider, videoID: video.videoID) }
    private var openURLValue: URL? { EmbedPolicy.watchURL(provider: video.provider, videoID: video.videoID, stored: video.url) }

    var body: some View {
        VStack(spacing: FJSpacing.l) {
            if let embedURL, !embedFailed {
                EmbedWebView(embedURL: embedURL, failed: $embedFailed)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(FJRadius.shape(FJRadius.card))
                    .accessibilityLabel(playerLabel)
            } else {
                fallback
            }
            if let openURLValue {
                Button {
                    openURL(openURLValue)
                } label: {
                    Label(openTitle, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.fjSecondary())
            }
        }
        .padding(FJSpacing.screenMargin)
        .frame(maxHeight: .infinity)
    }

    private var playerLabel: String {
        switch video.provider {
        case .youtube: String(localized: "Player de vídeo do YouTube")
        case .vimeo: String(localized: "Player de vídeo do Vimeo")
        case .other: String(localized: "Player de vídeo")
        }
    }

    private var openTitle: LocalizedStringKey {
        switch video.provider {
        case .youtube: "Abrir no YouTube"
        case .vimeo: "Abrir no Vimeo"
        case .other: "Abrir no Safari"
        }
    }

    @ViewBuilder
    private var fallback: some View {
        if video.provider == .other {
            FJEmptyState("Vídeo externo", systemImage: "safari",
                         message: "Este link abre no Safari.")
        } else {
            ZStack {
                MediaThumbnailView(media: .externalVideo(url: video.url, provider: video.provider, videoID: video.videoID),
                                   maxPixel: 800, showsPlayBadge: false, allowsRemoteThumbnail: true)
                    .opacity(0.35)
                FJEmptyState("Não foi possível tocar aqui", systemImage: "play.slash",
                             message: "O vídeo pode estar sem rede ou bloquear a exibição dentro de outros apps.")
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(FJColor.fill, in: FJRadius.shape(FJRadius.card))
            .clipShape(FJRadius.shape(FJRadius.card))
        }
    }
}

/// `WKWebView` com o embed oficial: sem autoplay, reprodução inline, dados não persistentes e navegação
/// restrita pela `EmbedPolicy`. Falhas de carga mostram o fallback; falhas dentro do iframe (embed bloqueado)
/// não são detectáveis, então o botão "Abrir no …" fica sempre visível.
private struct EmbedWebView: UIViewRepresentable {
    let embedURL: URL
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        // O baseURL dá ao embed uma origem https válida (sem ela o YouTube recusa o player).
        let base = URL(string: "https://\(embedURL.host() ?? "www.youtube-nocookie.com")/")
        context.coordinator.baseURL = base
        webView.loadHTMLString(EmbedPolicy.html(embedURL: embedURL), baseURL: base)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    /// Para o áudio ao fechar: interrompe a carga, solta o delegate e troca a página.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let failed: Binding<Bool>
        var baseURL: URL?

        init(failed: Binding<Bool>) { self.failed = failed }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed.wrappedValue = true }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed.wrappedValue = true }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let allowed = EmbedPolicy.allowsNavigation(
                to: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame ?? false,
                targetIsNil: navigationAction.targetFrame == nil,
                baseURL: baseURL
            )
            return allowed ? .allow : .cancel
        }
    }
}

// MARK: - Visualizador (tela cheia)

/// Moldura de apresentação do player com botão "Fechar".
struct ExerciseMediaViewer: View {
    let media: MediaRef
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ExerciseMediaView(media: media)
                .navigationTitle(media.accessibilityLabel())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Fechar") { dismiss() }
                    }
                }
        }
    }
}

#Preview("Link YouTube") {
    ExerciseMediaView(media: .externalVideo(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, provider: .youtube, videoID: "dQw4w9WgXcQ"))
}

#Preview("Link outro") {
    ExerciseMediaView(media: .externalVideo(url: URL(string: "https://example.com/v")!, provider: .other, videoID: nil))
}

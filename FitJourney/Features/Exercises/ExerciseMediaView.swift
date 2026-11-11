import AVKit
import SwiftUI
import WebKit

// MARK: - Descrições e rótulos

extension MediaRef {
    /// Texto para VoiceOver ("Foto 2 de 3").
    func accessibilityLabel(index: Int? = nil, of total: Int? = nil) -> String {
        let base: String = switch self {
        case .image: String(localized: "Foto")
        case .localVideo: String(localized: "Vídeo")
        case .externalVideo(_, let provider, _):
            switch provider {
            case .youtube: String(localized: "Vídeo do YouTube")
            case .vimeo: String(localized: "Vídeo do Vimeo")
            case .other: String(localized: "Link de vídeo")
            }
        }
        guard let index, let total, total > 1 else { return base }
        return String(localized: "\(base) \(index + 1) de \(total)")
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
struct MediaThumbnailView: View {
    let media: MediaRef
    /// Maior lado a decodificar (px).
    var maxPixel: Int = 400
    /// Mostra o símbolo de play sobre vídeos.
    var showsPlayBadge = true

    @State private var image: CGImage?
    @State private var didFail = false

    var body: some View {
        ZStack {
            FJColor.fill
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if case .externalVideo(let url, let provider, let id) = media,
                      provider == .youtube, let id,
                      let thumbURL = ExternalVideo(provider: provider, videoID: id, url: url).thumbnailURL {
                AsyncImage(url: thumbURL) { phase in
                    switch phase {
                    case .success(let loaded): loaded.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
            if showsPlayBadge, media.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.45))
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .task(id: media) { await load() }
    }

    private var placeholder: some View {
        Image(systemName: media.isVideo ? "video" : "photo")
            .font(.title2)
            .foregroundStyle(FJColor.textSecondary)
            .accessibilityHidden(true)
    }

    private func load() async {
        let name: String? = switch media {
        case .image(let fileName): fileName
        case .localVideo(_, let thumb): thumb
        case .externalVideo: nil
        }
        guard let name else { return }
        image = await MediaImageLoader.shared.image(for: name, maxPixel: maxPixel)
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
        withAnimation(FJMotion.value) {
            if scale > 1 { reset() } else { scale = 2.5; committedScale = 2.5 }
        }
    }

    private func reset() {
        scale = 1; committedScale = 1; offset = .zero; committedOffset = .zero
    }
}

// MARK: Vídeo local

private struct LocalVideoPlayer: View {
    let fileName: String
    @State private var player: AVPlayer?

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
        .onDisappear { player?.pause() }
    }
}

// MARK: YouTube / Vimeo / outros

private struct ExternalVideoPlayer: View {
    let video: ExternalVideo

    @Environment(\.openURL) private var openURL
    @State private var embedFailed = false

    private var providerName: String? {
        switch video.provider {
        case .youtube: "YouTube"
        case .vimeo: "Vimeo"
        case .other: nil
        }
    }

    var body: some View {
        VStack(spacing: FJSpacing.l) {
            if let embedURL = video.embedURL, !embedFailed {
                EmbedWebView(embedURL: embedURL, failed: $embedFailed)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(FJRadius.shape(FJRadius.card))
                    .accessibilityLabel(String(localized: "Player de vídeo do \(providerName ?? "")"))
            } else {
                fallback
            }
            Button {
                openURL(video.watchURL)
            } label: {
                Label(openTitle, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.fjSecondary())
        }
        .padding(FJSpacing.screenMargin)
        .frame(maxHeight: .infinity)
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
                if let thumb = video.thumbnailURL {
                    AsyncImage(url: thumb) { $0.resizable().scaledToFill().opacity(0.35) } placeholder: { Color.clear }
                }
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

/// `WKWebView` com o embed oficial. Sem autoplay, reprodução inline; navegação limitada ao próprio embed.
private struct EmbedWebView: UIViewRepresentable {
    let embedURL: URL
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent}iframe{border:0;width:100%;height:100%}</style></head>
        <body><iframe src="\(embedURL.absoluteString)" allow="encrypted-media; picture-in-picture; fullscreen" allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        // O baseURL dá ao embed uma origem https válida (sem ela o YouTube recusa o player).
        let base = URL(string: "https://\(embedURL.host() ?? "www.youtube-nocookie.com")/")
        webView.loadHTMLString(html, baseURL: base)
        context.coordinator.startTimeout()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let failed: Binding<Bool>
        private var finished = false

        init(failed: Binding<Bool>) { self.failed = failed }

        /// Sem carregar em 15 s (sem rede, embed bloqueado): mostra o fallback.
        func startTimeout() {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, !self.finished else { return }
                self.failed.wrappedValue = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail() }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail() }

        private func fail() {
            finished = true
            failed.wrappedValue = true
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Só o carregamento inicial e o iframe do embed; links clicados dentro do player não saem do app.
            navigationAction.navigationType == .other ? .allow : .cancel
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

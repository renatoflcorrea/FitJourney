import SwiftUI

/// Tipo de anexo enviado ao copiloto (SPEC §7A.1).
enum FJAttachmentKind: String, CaseIterable, Sendable {
    case pdf, image, text

    var systemImage: String {
        switch self {
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .text: "text.alignleft"
        }
    }

    /// Rótulo curto que aparece na miniatura sem prévia e na leitura do VoiceOver.
    var title: LocalizedStringResource {
        switch self {
        case .pdf: "PDF"
        case .image: "Foto"
        case .text: "Texto"
        }
    }
}

/// Estado de um anexo na seleção de arquivos.
enum FJAttachmentState: Equatable, Sendable {
    case ready
    /// Sendo preparado (redimensionando a foto, contando páginas).
    case preparing
    /// Não pode ser enviado; o texto curto diz por quê ("Maior que 20 MB", "Ilegível").
    case failed(String)
}

/// Miniatura de anexo (DESIGN_DIRECTION §4.15.3): prévia da primeira página/da foto, nº de páginas,
/// nome e tamanho, com botão de remover. Sólida — é conteúdo, não flutua.
///
/// O alvo de remover tem 44 pt (o círculo visível tem 24 pt). Cresce com o Dynamic Type até 1,3×.
struct FJAttachmentThumb: View {
    private let name: String
    private let kind: FJAttachmentKind
    private let detail: String?
    private let pageCount: Int?
    private let preview: Image?
    private let state: FJAttachmentState
    private let onRemove: (() -> Void)?

    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    /// - Parameters:
    ///   - name: nome do arquivo como o usuário conhece ("Treino João.pdf", "Foto 1", "Texto colado").
    ///   - detail: tamanho ou resumo ("1,2 MB", "340 caracteres").
    ///   - pageCount: páginas do PDF (ou fotos de um mesmo documento); `nil` ou 1 não mostra o selo.
    ///   - preview: miniatura já reduzida; sem ela, mostra o símbolo do tipo.
    ///   - onRemove: `nil` deixa a miniatura só de leitura (revisão, origem).
    init(
        name: String,
        kind: FJAttachmentKind,
        detail: String? = nil,
        pageCount: Int? = nil,
        preview: Image? = nil,
        state: FJAttachmentState = .ready,
        onRemove: (() -> Void)? = nil
    ) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.pageCount = pageCount
        self.preview = preview
        self.state = state
        self.onRemove = onRemove
    }

    private var factor: CGFloat { min(max(scale, 1), 1.3) }
    private var failure: String? {
        if case let .failed(reason) = state { reason } else { nil }
    }

    var body: some View {
        let width = FJAttachmentMetrics.width * factor
        VStack(alignment: .leading, spacing: FJSpacing.xs) {
            tile
                .frame(width: width, height: FJAttachmentMetrics.height * factor)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FJColor.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let failure {
                    Text(verbatim: failure)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FJColor.textPrimary)
                } else if let detail {
                    Text(verbatim: detail)
                        .font(.caption2)
                        .foregroundStyle(FJColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityActions {
            if let onRemove {
                Button("Remover", action: onRemove)
            }
        }
    }

    private var tile: some View {
        let shape = FJRadius.shape(FJRadius.field)
        return ZStack {
            shape.fill(FJColor.surface)
            if let preview {
                preview
                    .resizable()
                    .scaledToFill()
                    .opacity(state == .ready ? 1 : 0.35)
            } else if failure == nil {
                VStack(spacing: FJSpacing.xs) {
                    Image(systemName: kind.systemImage)
                        .font(.title2)
                    Text(kind.title)
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(FJColor.textSecondary)
            }
            if state == .preparing {
                ProgressView()
            }
            if failure != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(FJColor.attention)
                    .padding(FJSpacing.s)
                    .background(FJColor.surface, in: Circle())
                    .opacity(preview == nil ? 1 : 0.92)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(failure == nil ? FJColor.separator : FJColor.attention,
                               lineWidth: failure == nil ? 0.5 : 1.5)
        }
        .overlay(alignment: .bottomLeading) {
            if let pageCount, pageCount > 1 {
                Text("\(pageCount) pág.")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(FJColor.textPrimary)
                    .padding(.horizontal, FJSpacing.xs + FJSpacing.xxs)
                    .padding(.vertical, FJSpacing.xxs)
                    .background(FJColor.surfaceElevated, in: Capsule())
                    .overlay(Capsule().strokeBorder(FJColor.separator, lineWidth: 0.5))
                    .padding(FJSpacing.xs)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FJColor.textPrimary)
                        .frame(width: 24, height: 24)
                        .background(FJColor.surfaceElevated, in: Circle())
                        .overlay(Circle().strokeBorder(FJColor.separator, lineWidth: 0.5))
                        .frame(width: FJSize.minTap, height: FJSize.minTap, alignment: .topTrailing)
                        .padding(FJSpacing.xs)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var spokenLabel: Text {
        var parts = [name, String(localized: kind.title)]
        if let pageCount, pageCount > 1 {
            parts.append(String(localized: "\(pageCount) páginas"))
        }
        if let failure {
            parts.append(failure)
        } else if let detail {
            parts.append(detail)
        }
        if state == .preparing {
            parts.append(String(localized: "Preparando"))
        }
        return Text(verbatim: parts.joined(separator: ", "))
    }
}

/// Medidas base da miniatura (proporção de página, 3:4).
enum FJAttachmentMetrics {
    static let width: CGFloat = 84
    static let height: CGFloat = 112
}

/// Quadro "Adicionar" no fim da grade de anexos: mesma medida da miniatura, contorno tracejado.
struct FJAttachmentAddTile: View {
    private let title: LocalizedStringKey
    private let action: () -> Void

    @ScaledMetric(relativeTo: .caption) private var scale: CGFloat = 1

    init(_ title: LocalizedStringKey = "Adicionar", action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        let factor = min(max(scale, 1), 1.3)
        let shape = FJRadius.shape(FJRadius.field)
        Button(action: action) {
            VStack(spacing: FJSpacing.xs) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(FJColor.coach)
            .frame(width: FJAttachmentMetrics.width * factor, height: FJAttachmentMetrics.height * factor)
            .background(FJColor.coach.opacity(0.08), in: shape)
            .overlay {
                shape.strokeBorder(FJColor.coach, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
    }
}

/// Origem de um item extraído (SPEC §7A.1 `source`): "Treino João.pdf · p. 2".
struct FJSourceLabel: View {
    private let file: String
    private let page: Int?

    init(file: String, page: Int? = nil) {
        self.file = file
        self.page = page
    }

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            Image(systemName: "doc.text.magnifyingglass")
                .accessibilityHidden(true)
            if let page {
                Text("\(file) · p. \(page)")
            } else {
                Text(verbatim: file)
            }
        }
        .font(FJFont.caption)
        .foregroundStyle(FJColor.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page.map { Text("Origem: \(file), página \($0)") } ?? Text("Origem: \(file)"))
    }
}

#Preview("Anexos") {
    ZStack {
        FJColor.background.ignoresSafeArea()
        VStack(alignment: .leading, spacing: FJSpacing.l) {
            FJFlowLayout(spacing: FJSpacing.m) {
                FJAttachmentThumb(name: "Treino João.pdf", kind: .pdf, detail: "1,2 MB", pageCount: 4) {}
                FJAttachmentThumb(name: "Foto 1", kind: .image, detail: "820 KB") {}
                FJAttachmentThumb(name: "Texto colado", kind: .text, detail: "340 caracteres") {}
                FJAttachmentThumb(name: "Dieta antiga.pdf", kind: .pdf, state: .failed("Maior que 20 MB")) {}
                FJAttachmentThumb(name: "Foto 2", kind: .image, state: .preparing)
                FJAttachmentAddTile {}
            }
            FJSourceLabel(file: "Treino João.pdf", page: 2)
        }
        .padding(FJSpacing.screenMargin)
    }
}

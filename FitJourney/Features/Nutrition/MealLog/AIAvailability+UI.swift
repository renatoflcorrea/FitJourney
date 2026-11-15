import SwiftUI

extension Optional where Wrapped == AIAvailability {
    /// IA configurada (SPEC §7.x). Sem `AIAvailability` no ambiente (previews, testes), os recursos de IA ficam escondidos.
    @MainActor var isOn: Bool { self?.isAvailable == true }

    /// IA configurada e o modelo lê fotos (câmera do registro com IA).
    @MainActor var canReadImages: Bool { self?.supportsImages == true }
}

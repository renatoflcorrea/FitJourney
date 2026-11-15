import AVFoundation
import SwiftUI
import UIKit

/// Câmera do sistema (uma foto por vez) do registro com IA. A permissão é pedida pelo sistema ao abrir, só quando o
/// usuário toca na câmera. Entrega o JPEG da foto tirada; quem recebe grava em Fotos e envia à análise.
struct MealCameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: MealCameraPicker
        init(_ parent: MealCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

enum MealCamera {
    /// O aparelho tem câmera (o simulador não tem).
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    /// Permissão negada ou restrita: mostrar o alerta com "Abrir Ajustes" em vez de abrir a câmera.
    static var isDenied: Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: true
        default: false
        }
    }
}

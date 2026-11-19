import Foundation
import UniformTypeIdentifiers

/// Conteúdo de demonstração empacotado no app (proposta ai-consent-review §4; App Review 2.1(a)): fichas e plano
/// fictícios, marcados "APP REVIEW SAMPLE", gerados por `scripts/make-review-samples.sh`. Passam pelo mesmo
/// consentimento de qualquer arquivo antes de ir ao provedor.
enum ImportSamples {
    /// Ficha principal: a mais variada (repetições, faixas, duração, carga e cardio).
    static let mainWorkout = "SampleWorkoutChestBiceps"
    static let otherWorkouts = ["SampleWorkoutBackTriceps", "SampleWorkoutLegs", "SampleWorkoutShoulders"]
    static let mealPlan = "SampleMealPlan"

    static func workout(_ resource: String, bundle: Bundle = .main) -> RawAttachment? {
        guard let url = bundle.url(forResource: resource, withExtension: "jpg"), let data = try? Data(contentsOf: url) else { return nil }
        return RawAttachment(filename: filename(for: resource), data: data, typeHint: UTType.jpeg.identifier)
    }

    static func mealPlanAttachment(bundle: Bundle = .main) -> RawAttachment? {
        guard let url = bundle.url(forResource: mealPlan, withExtension: "pdf"), let data = try? Data(contentsOf: url) else { return nil }
        return RawAttachment(filename: String(localized: "Plano alimentar de exemplo.pdf"), data: data, typeHint: UTType.pdf.identifier)
    }

    /// Nomes dos anexos de exemplo (o primeiro é o da ficha principal; os outros dizem o grupo).
    static func filename(for resource: String) -> String {
        switch resource {
        case "SampleWorkoutBackTriceps": String(localized: "Ficha de exemplo · costas.jpg")
        case "SampleWorkoutLegs": String(localized: "Ficha de exemplo · pernas.jpg")
        case "SampleWorkoutShoulders": String(localized: "Ficha de exemplo · ombros.jpg")
        default: String(localized: "Ficha de exemplo.jpg")
        }
    }

    static var sampleFilenames: Set<String> {
        Set(([mainWorkout] + otherWorkouts).map(filename(for:)) + [String(localized: "Plano alimentar de exemplo.pdf")])
    }

    /// Texto de exemplo do registro de refeição (preenche o campo; não envia sozinho).
    static var mealLogText: String {
        String(localized: "Café da manhã: 2 ovos mexidos, 1 pão francês com manteiga e café com leite. À tarde, um açaí de 300 ml com granola.")
    }
}

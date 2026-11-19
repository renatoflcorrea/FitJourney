import SwiftUI

struct ModelListView: View {
    let models: [String]
    let selectedModel: String
    let preferredModel: String?
    let onSelect: (String) -> Void
    @State private var searchText = ""

    private var filteredModels: [String] {
        guard !searchText.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        List {
            ForEach(filteredModels, id: \.self) { model in
                Button {
                    onSelect(model)
                } label: {
                    VStack(alignment: .leading, spacing: FJSpacing.xxs) {
                        HStack {
                            Text(model).foregroundStyle(FJColor.textPrimary)
                            Spacer()
                            if model == selectedModel { Image(systemName: "checkmark").foregroundStyle(FJArea.coach.color) }
                        }
                        if model == preferredModel { Text("Padrão · mais leve e rápido").font(FJFont.caption).foregroundStyle(FJColor.textSecondary) }
                    }.frame(minHeight: FJSize.minTap)
                }
                .accessibilityIdentifier("settings.ai.model.\(model)")
                .accessibilityAddTraits(model == selectedModel ? .isSelected : [])
            }
        }
        .navigationTitle("Modelos")
        .searchable(text: $searchText, prompt: "Buscar modelos")
    }
}

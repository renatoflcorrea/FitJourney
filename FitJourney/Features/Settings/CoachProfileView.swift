import SwiftUI

/// Perfil opcional que o Coach usa como contexto (SPEC §7). Tudo é opcional e só vai ao provedor
/// se "Perfil" estiver ligado em Ajustes de IA.
struct CoachProfileView: View {
    private let defaults: UserDefaults
    @State private var profile: CoachProfile

    init() {
        self.init(defaults: .standard)
    }

    /// Para previews e testes.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        _profile = State(initialValue: CoachProfileStore(defaults: defaults).load())
    }

    var body: some View {
        Form {
            Section {
                TextField("Idade", value: $profile.age, format: .number)
                    .keyboardType(.numberPad)
                Picker("Sexo", selection: $profile.sex) {
                    Text("Não informar").tag(CoachProfile.Sex?.none)
                    Text("Feminino").tag(CoachProfile.Sex?.some(.female))
                    Text("Masculino").tag(CoachProfile.Sex?.some(.male))
                    Text("Outro").tag(CoachProfile.Sex?.some(.other))
                }
                TextField("Altura (cm)", value: $profile.heightCm, format: .number)
                    .keyboardType(.decimalPad)
                TextField("Peso (kg)", value: $profile.weightKg, format: .number)
                    .keyboardType(.decimalPad)
            } header: {
                Text("Sobre você")
            }
            Section("Treino") {
                Picker("Nível", selection: $profile.level) {
                    Text("Não informar").tag(CoachProfile.Level?.none)
                    Text("Iniciante").tag(CoachProfile.Level?.some(.beginner))
                    Text("Intermediário").tag(CoachProfile.Level?.some(.intermediate))
                    Text("Avançado").tag(CoachProfile.Level?.some(.advanced))
                }
                TextField("Objetivo", text: text(\.goal), axis: .vertical)
                TextField("Dias por semana", value: $profile.daysPerWeek, format: .number)
                    .keyboardType(.numberPad)
                TextField("Minutos por sessão", value: $profile.minutesPerSession, format: .number)
                    .keyboardType(.numberPad)
                TextField("Equipamentos disponíveis", text: text(\.equipment), axis: .vertical)
            }
            Section {
                TextField("Restrições e lesões", text: text(\.restrictions), axis: .vertical)
            } footer: {
                Text("O Coach não faz diagnóstico nem prescrição médica. Com dor, lesão ou condição de saúde, procure um profissional.")
            }
            Section("Alimentação") {
                TextField("Preferências e alergias", text: text(\.foodPreferences), axis: .vertical)
            }
        }
        .navigationTitle("Perfil do Coach")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: profile) { save() }
    }

    /// `String?` ↔ campo de texto; vazio vira `nil`.
    private func text(_ keyPath: WritableKeyPath<CoachProfile, String?>) -> Binding<String> {
        Binding(get: { profile[keyPath: keyPath] ?? "" },
                set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    /// Não sobrescreve o compartilhamento, que Ajustes de IA pode ter mudado.
    private func save() {
        let store = CoachProfileStore(defaults: defaults)
        var toSave = profile
        toSave.sharing = store.load().sharing
        store.save(toSave)
    }
}

#if DEBUG
#Preview("Perfil do Coach") {
    NavigationStack { CoachProfileView(defaults: CoachPreviewData.defaults(consented: true)) }
        .tint(FJColor.coach)
}
#endif

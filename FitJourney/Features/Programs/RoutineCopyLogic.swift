import SwiftData
import SwiftUI

// Lógica de apresentação de "Copiar ficha para outro programa" (DESIGN §4.2.1).
// A regra de negócio (cópia, nome, dias sugeridos) fica em `ProgramStore` e `RoutineNaming`; aqui só a
// escolha do que mostrar nas folhas.

/// Navegação "Ver programa": a raiz de Treinos (programa ativo) ou o detalhe do programa. Quem hospeda a
/// pilha de Treinos injeta a ação; fora dela (ex.: editor aberto pelo Coach) a ação não faz nada.
struct OpenProgramAction: Sendable {
    let run: @MainActor @Sendable (TrainingProgram) -> Void

    static let none = OpenProgramAction { _ in }

    init(_ run: @escaping @MainActor @Sendable (TrainingProgram) -> Void) { self.run = run }

    @MainActor func callAsFunction(_ program: TrainingProgram) { run(program) }
}

extension EnvironmentValues {
    @Entry var openProgram: OpenProgramAction = .none
}

enum RoutineCopyLogic {
    /// Programas para escolher, na ordem do DESIGN: ativo, anteriores (mais recente primeiro), arquivados.
    /// `programs` já vem do mais recente para o mais antigo (`startDate` decrescente).
    static func orderedPrograms(_ programs: [TrainingProgram], excluding source: TrainingProgram?) -> [TrainingProgram] {
        let others = programs.filter { $0.persistentModelID != source?.persistentModelID }
        return others.filter(\.isActive)
            + others.filter { !$0.isActive && !$0.isArchived }
            + others.filter { !$0.isActive && $0.isArchived }
    }

    /// "Sequencial · 3 fichas".
    static func summary(of program: TrainingProgram) -> String {
        let count = (program.routines ?? []).count
        return "\(program.scheduleMode.localizedName) · \(String(localized: "\(count) fichas"))"
    }

    /// Nome com que a ficha entra no destino (ver `RoutineNaming`).
    static func finalName(of routine: Routine, in destination: TrainingProgram) -> String {
        RoutineNaming.uniqueName(routine.name, among: destination.sortedRoutines.map(\.name))
    }

    /// Frase do rodapé do fluxo A conforme o destino marcado.
    static func placementFooter(for destination: TrainingProgram) -> String {
        switch destination.scheduleMode {
        case .free: String(localized: "Entra na lista de fichas de \(destination.name).")
        case .sequential: String(localized: "Entra no fim da sequência de \(destination.name).")
        case .weekly: String(localized: "\(destination.name) é semanal. No próximo passo você escolhe os dias.")
        }
    }

    /// Frase de abertura do fluxo B conforme o destino.
    static func placementIntro(for destination: TrainingProgram) -> String {
        switch destination.scheduleMode {
        case .free: String(localized: "Entram na lista de fichas.")
        case .sequential: String(localized: "Entram no fim da sequência, na ordem desta lista.")
        case .weekly: String(localized: "No próximo passo você escolhe os dias.")
        }
    }

    /// Cabeçalho de grupo do fluxo B: "Força 5×5 · Ativo".
    static func groupTitle(for program: TrainingProgram) -> String {
        if program.isActive { return String(localized: "\(program.name) · Ativo") }
        if program.isArchived { return String(localized: "\(program.name) · Arquivado") }
        return program.name
    }

    /// Dias já marcados → nomes das fichas que os ocupam (fichas do destino e outras fichas desta cópia).
    static func usedDays(destination: TrainingProgram, others: [(name: String, days: Set<Weekday>)]) -> [Weekday: [String]] {
        var result: [Weekday: [String]] = [:]
        for routine in destination.sortedRoutines {
            for day in routine.weekdays { result[day, default: []].append(routine.name) }
        }
        for other in others {
            for day in other.days { result[day, default: []].append(other.name) }
        }
        return result
    }

    /// Aviso "Dia já usado por outra ficha: Ter (B — Costas e bíceps)…" (mesmo texto de "Nova ficha").
    static func conflictText(days: Set<Weekday>, used: [Weekday: [String]]) -> String? {
        let clashes = days.sorted().compactMap { day in used[day].map { (day, $0) } }
        guard !clashes.isEmpty else { return nil }
        let list = clashes.map { "\($0.0.shortName) (\($0.1.joined(separator: ", ")))" }.joined(separator: "; ")
        return String(localized: "Dia já usado por outra ficha: \(list). Os dois treinos aparecem no mesmo dia.")
    }
}

/// Uma ficha no passo "Dias da semana".
struct CopyDayItem: Identifiable {
    /// `Routine.id` da ficha original (chave de `copyRoutines(weekdays:)`).
    let id: UUID
    let symbol: String
    let colorName: String
    /// Nome com que a ficha entra no destino.
    let name: String
    /// Dias sugeridos (os da original, se vem de programa semanal).
    let suggested: Set<Weekday>
}

/// Passo "Dias da semana" (push na folha; só com destino semanal): `WeekdayPicker` por ficha, com os dias
/// da original já marcados e ponto nos dias ocupados. Nada bloqueia: dia ocupado e ficha sem dia são permitidos.
struct RoutineCopyDaysStep: View {
    let destination: TrainingProgram
    let items: [CopyDayItem]
    @Binding var days: [UUID: Set<Weekday>]
    let confirmTitle: LocalizedStringKey
    let confirmAccessibilityLabel: Text?
    let isDisabled: Bool
    let onConfirm: () -> Void

    private var intro: String {
        items.count > 1
            ? String(localized: "Escolha em que dias cada ficha entra em \(destination.name). Dois treinos podem cair no mesmo dia.")
            : String(localized: "Escolha em que dias a ficha entra em \(destination.name). Dois treinos podem cair no mesmo dia.")
    }

    var body: some View {
        List {
            Section {
                Text(verbatim: intro)
                    .font(FJFont.label)
                    .foregroundStyle(FJColor.textSecondary)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: FJSpacing.s, bottom: 0, trailing: FJSpacing.s))
            }
            ForEach(items) { item in
                let used = RoutineCopyLogic.usedDays(destination: destination, others: others(than: item))
                Section {
                    WeekdayPicker(selection: binding(for: item), usedByOthers: Set(used.keys))
                        .padding(.vertical, FJSpacing.xs)
                } header: {
                    HStack(spacing: FJSpacing.s) {
                        FJRoutineBadge(symbol: item.symbol, name: item.name, colorName: item.colorName, size: .sm)
                        Text(verbatim: item.name)
                            .font(FJFont.cardTitle)
                            .foregroundStyle(FJColor.textPrimary)
                    }
                    .textCase(nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                } footer: {
                    footer(for: item, used: used)
                }
            }
        }
        .navigationTitle("Dias da semana")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle, action: onConfirm)
                    .disabled(isDisabled)
                    .accessibilityLabel(confirmAccessibilityLabel ?? Text(confirmTitle))
            }
        }
        .fjHaptic(.selection, trigger: days)
    }

    private func others(than item: CopyDayItem) -> [(name: String, days: Set<Weekday>)] {
        items.filter { $0.id != item.id }.map { ($0.name, days[$0.id] ?? $0.suggested) }
    }

    private func binding(for item: CopyDayItem) -> Binding<Set<Weekday>> {
        Binding(get: { days[item.id] ?? item.suggested }, set: { days[item.id] = $0 })
    }

    private func footer(for item: CopyDayItem, used: [Weekday: [String]]) -> some View {
        let chosen = days[item.id] ?? item.suggested
        return VStack(alignment: .leading, spacing: FJSpacing.xs) {
            Text(item.suggested.isEmpty
                 ? "A ficha original não tem dias marcados."
                 : "Sugestão: os dias da ficha original.")
            if let conflict = RoutineCopyLogic.conflictText(days: chosen, used: used) {
                Label(conflict, systemImage: "info.circle.fill")
            }
            if chosen.isEmpty {
                Text("Sem dia marcado, a ficha entra no programa, mas não é sugerida em Hoje.")
            }
        }
    }
}

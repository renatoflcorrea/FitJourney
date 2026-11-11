import SwiftUI

/// Badge de zona de FC: ponto colorido + "Z3" + nome. A cor nunca aparece sozinha.
struct FJHeartRateZoneBadge: View {
    private let zone: FJHeartRateZone
    private let showsName: Bool

    init(_ zone: FJHeartRateZone, showsName: Bool = true) {
        self.zone = zone
        self.showsName = showsName
    }

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            Circle()
                .fill(zone.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(verbatim: zone.shortLabel)
                .font(FJFont.numberCaption.weight(.semibold))
            if showsName {
                Text(zone.name)
                    .font(.caption)
            }
        }
        .foregroundStyle(FJColor.textPrimary)
        .padding(.horizontal, FJSpacing.s)
        .padding(.vertical, FJSpacing.xs)
        .background(zone.color.opacity(0.18), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Zona \(zone.rawValue)"))
        .accessibilityValue(Text(zone.name))
    }
}

/// FC atual: coração + bpm + zona. `bpm == nil` = indisponível ("—"), nunca zero.
struct FJHeartRateBadge: View {
    private let bpm: Int?
    private let zone: FJHeartRateZone?

    init(bpm: Int?, zone: FJHeartRateZone? = nil) {
        self.bpm = bpm
        self.zone = zone
    }

    var body: some View {
        HStack(spacing: FJSpacing.xs) {
            Image(systemName: bpm == nil ? "heart.slash" : "heart.fill")
                .foregroundStyle(bpm == nil ? FJColor.textSecondary : FJColor.health)
            Text(verbatim: bpm.map(String.init) ?? "—")
                .font(FJFont.numberBody.weight(.semibold))
                .fjNumericTransition()
            Text(verbatim: "bpm")
                .font(.caption)
                .foregroundStyle(FJColor.textSecondary)
            if let zone, bpm != nil {
                FJHeartRateZoneBadge(zone, showsName: false)
            }
        }
        .foregroundStyle(FJColor.textPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Frequência cardíaca"))
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityValue: Text {
        guard let bpm else { return Text("Indisponível") }
        guard let zone else { return Text("\(bpm) batimentos por minuto") }
        return Text("\(bpm) batimentos por minuto, zona \(zone.rawValue)")
    }
}

#Preview("Frequência cardíaca") {
    ScrollView {
        VStack(spacing: FJSpacing.cardGap) {
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.s) {
                    ForEach(FJHeartRateZone.allCases, id: \.self) { zone in
                        FJHeartRateZoneBadge(zone)
                    }
                }
            }
            FJCard {
                VStack(alignment: .leading, spacing: FJSpacing.m) {
                    FJHeartRateBadge(bpm: 142, zone: .z3)
                    FJHeartRateBadge(bpm: 96)
                    FJHeartRateBadge(bpm: nil)
                }
            }
        }
        .padding(FJSpacing.screenMargin)
    }
    .fjScreenBackground()
}

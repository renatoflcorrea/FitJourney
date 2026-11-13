import SwiftUI
import WidgetKit

/// Complicação de atalho (v1): abre o app do relógio. Não mostra dados do treino.
struct ShortcutEntry: TimelineEntry {
    let date: Date
}

struct ShortcutProvider: TimelineProvider {
    func placeholder(in context: Context) -> ShortcutEntry {
        ShortcutEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ShortcutEntry) -> Void) {
        completion(ShortcutEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ShortcutEntry>) -> Void) {
        completion(Timeline(entries: [ShortcutEntry(date: .now)], policy: .never))
    }
}

struct FitJourneyShortcutWidget: Widget {
    static let kind = "br.com.renatocorrea.fitjourney.watch.shortcut"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ShortcutProvider()) { _ in
            ShortcutComplicationView()
        }
        .configurationDisplayName("FitJourney")
        .description("Abra o FitJourney no pulso.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

struct ShortcutComplicationView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryCorner:
            corner
                .widgetLabel { Text("FitJourney") }
                .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            HStack(spacing: 8) {
                StairGlyph()
                    .fill(.primary)
                    .frame(width: 30, height: 30)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 2) {
                    Text("FitJourney")
                        .font(.headline)
                        .widgetAccentable()
                    Text("Seus treinos")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryInline:
            Label("FitJourney", systemImage: "figure.strengthtraining.traditional")
                .containerBackground(for: .widget) { Color.clear }
        default:
            Text("FitJourney")
                .containerBackground(for: .widget) { Color.clear }
        }
    }

    @ViewBuilder
    private var corner: some View {
        if renderingMode == .fullColor {
            Image(decorative: "ComplicationGlassCorner")
                .resizable()
                .scaledToFit()
                .accessibilityElement()
                .accessibilityLabel(Text("FitJourney"))
        } else {
            StairGlyph()
                .fill(.primary)
                .padding(7)
                .widgetAccentable()
                .accessibilityElement()
                .accessibilityLabel(Text("FitJourney"))
        }
    }

    @ViewBuilder
    private var circular: some View {
        if renderingMode == .fullColor {
            Image(decorative: "ComplicationGlass")
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
                .accessibilityElement()
                .accessibilityLabel(Text("FitJourney"))
                .containerBackground(for: .widget) { Color.clear }
        } else {
            StairGlyph()
                .fill(.primary)
                .padding(9)
                .widgetAccentable()
                .accessibilityElement()
                .accessibilityLabel(Text("FitJourney"))
                .containerBackground(for: .widget) { AccessoryWidgetBackground() }
        }
    }
}

#if DEBUG
#Preview("Circular", as: .accessoryCircular) {
    FitJourneyShortcutWidget()
} timeline: {
    ShortcutEntry(date: .now)
}

#Preview("Corner", as: .accessoryCorner) {
    FitJourneyShortcutWidget()
} timeline: {
    ShortcutEntry(date: .now)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    FitJourneyShortcutWidget()
} timeline: {
    ShortcutEntry(date: .now)
}

#Preview("Inline", as: .accessoryInline) {
    FitJourneyShortcutWidget()
} timeline: {
    ShortcutEntry(date: .now)
}
#endif

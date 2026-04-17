import SwiftUI

enum SettingsTab: String, CaseIterable, Hashable, Identifiable {
    case general, transcription, refinement, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:       "General"
        case .transcription: "Transcription"
        case .refinement:    "Refinement"
        case .advanced:      "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general:       "gearshape"
        case .transcription: "waveform"
        case .refinement:    "text.bubble"
        case .advanced:      "slider.horizontal.3"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabBar(selection: $selection)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 580, minHeight: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .general:       GeneralTab()
        case .transcription: TranscriptionTab()
        case .refinement:    RefinementTab()
        case .advanced:      AdvancedTab()
        }
    }
}

private struct SettingsTabBar: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { tab in
                SettingsTabButton(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .imageScale(.medium)
                Text(tab.title)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(minWidth: 110)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(background)
            )
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        } else if isHovering {
            return Color.primary.opacity(0.06)
        } else {
            return .clear
        }
    }
}

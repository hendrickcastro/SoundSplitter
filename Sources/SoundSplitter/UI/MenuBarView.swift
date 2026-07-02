import SwiftUI

/// Menu-bar popover UI, styled after FineTune: a dark glass panel with flat
/// rows. Each source shows its icon, where it's routed, a volume slider, and a
/// device picker. Routing is live the moment you pick a device.
struct MenuBarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: DS.sm) {
            header
            SectionHeader("Fuentes de audio")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.displaySources) { source in
                        SourceRow(state: state, source: source)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)
            Divider().opacity(0.5)
            footer
        }
        .padding(DS.md)
        .frame(width: 380)
        .glassBackground()
    }

    private var header: some View {
        HStack(spacing: DS.sm) {
            Image(systemName: "waveform.path")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 15, weight: .semibold))
            Text("SoundSplitter")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(state.totalActiveRoutes > 0 ? "\(state.totalActiveRoutes) activa(s)" : "en reposo")
                .font(DS.rowSubtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.xs) {
            if let message = state.statusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    state.refresh()
                } label: {
                    Label("Actualizar", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Text("Salir  ⌘Q").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Uppercase, tracked section header.
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(DS.sectionHeader)
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.sm)
    }
}

/// One source (system or app): icon + routing subtitle + device picker on the
/// first line; mute + volume slider + percentage on the second.
struct SourceRow: View {
    @ObservedObject var state: AppState
    let source: DisplaySource

    private var key: SourceKey { source.key }
    private var count: Int { state.enabledCount(for: key) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: DS.sm) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title).font(DS.rowTitle).lineLimit(1)
                    Text(state.routingDescription(for: key))
                        .font(DS.rowSubtitle)
                        .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: DS.sm)
                if source.isPlaying {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                }
                DevicePicker(state: state, key: key)
            }

            if count > 0 {
                HStack(spacing: DS.sm) {
                    MuteButton(muted: state.isMuted(for: key), volume: state.volume(for: key)) {
                        state.setMuted(!state.isMuted(for: key), for: key)
                    }
                    Slider(value: Binding(
                        get: { state.volume(for: key) },
                        set: { state.setVolume($0, for: key) }
                    ), in: 0...1)
                    .controlSize(.small)
                    .tint(.accentColor)
                    Text("\(Int(state.volume(for: key) * 100))%")
                        .font(DS.percentage)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.leading, 32)
                .opacity(state.isMuted(for: key) ? 0.5 : 1)
            }
        }
        .padding(.horizontal, DS.sm)
        .padding(.vertical, 6)
        .hoverRow(isSelected: count > 0)
    }

    @ViewBuilder private var icon: some View {
        if let appIcon = source.appIcon {
            Image(nsImage: appIcon).resizable().frame(width: 24, height: 24)
        } else {
            Image(systemName: "macwindow")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 18))
                .frame(width: 24, height: 24)
        }
    }
}

/// Icon-only dropdown to choose which output device(s) a source plays to.
struct DevicePicker: View {
    @ObservedObject var state: AppState
    let key: SourceKey

    private var count: Int { state.enabledCount(for: key) }

    var body: some View {
        Menu {
            if state.outputDevices.isEmpty {
                Text("No hay dispositivos de salida")
            }
            ForEach(state.outputDevices) { device in
                Button {
                    state.toggleOutput(device.id, for: key)
                } label: {
                    Label(
                        labelText(device),
                        systemImage: state.isEnabled(device.id, for: key) ? "checkmark" : ""
                    )
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: count > 0 ? "hifispeaker.2.fill" : "hifispeaker")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 12))
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(count > 0 ? Color.accentColor : .secondary)
            .padding(.horizontal, DS.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.buttonRadius)
                    .fill(count > 0 ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func labelText(_ device: AudioDevice) -> String {
        device.isBluetooth ? "\(device.name) · Bluetooth" : device.name
    }
}

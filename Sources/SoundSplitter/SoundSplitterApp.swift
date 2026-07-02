import SwiftUI
import AppKit
import Combine

@main
struct SoundSplitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The UI is driven entirely from AppKit (NSStatusItem + NSPopover) for
        // reliable click/focus behavior in an agent app. We still need a Scene,
        // so expose an empty Settings scene.
        Settings { EmptyView() }
    }
}

/// Owns the menu-bar status item and the popover hosting the SwiftUI UI.
/// Using AppKit here (instead of SwiftUI's `MenuBarExtra`) avoids the
/// unresponsive-popover issue seen with window-style MenuBarExtra in
/// SPM-bundled agent apps, and guarantees a working Quit path.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Freeze/crash logging to ~/Library/Logs/SoundSplitter/soundsplitter.log
        Diagnostics.install()

        // Menu-bar-only agent: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Popover hosting the SwiftUI view.
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: MenuBarView(state: state))

        // Status bar item.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = icon(running: state.masterEnabled)
            button.image?.isTemplate = true
            button.action = #selector(handleClick(_:))
            button.target = self
            // Receive both left and right mouse-up events.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Keep the menu-bar glyph in sync with running state.
        cancellable = state.$masterEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] running in
                MainActor.assumeIsolated {
                    self?.statusItem.button?.image = self?.icon(running: running)
                    self?.statusItem.button?.image?.isTemplate = true
                }
            }
    }

    private func icon(running: Bool) -> NSImage? {
        let name = running ? "waveform.path" : "waveform"
        return NSImage(systemSymbolName: name, accessibilityDescription: "SoundSplitter")
    }

    /// Left-click toggles the popover; right-click shows a minimal menu that
    /// always lets the user quit, even if the popover ever misbehaves.
    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            // Bring the popover to the front so sliders/toggles receive events.
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(
            withTitle: state.masterEnabled ? "Detener" : "Iniciar",
            action: #selector(toggleRunning),
            keyEquivalent: ""
        ).target = self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Salir de SoundSplitter",
            action: #selector(quit),
            keyEquivalent: "q"
        ).target = self

        // Show the menu, then immediately clear it so left-click keeps toggling
        // the popover afterwards.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRunning() { state.toggleRunning() }
    @objc private func quit() { NSApp.terminate(nil) }
}

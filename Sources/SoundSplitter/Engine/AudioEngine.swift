import CoreAudio
import Foundation

/// Identifies a routing source: the whole system, or one specific app.
enum SourceKey: Hashable {
    case system
    case app(String)   // stable app identity (see AudioProcess.id)
}

/// A complete routing instruction for one source: send it to these outputs,
/// at this volume. The engine reconciles the live world to match a list of
/// these.
struct SourcePlan {
    let key: SourceKey
    let source: RoutedSource.Source
    let outputs: [AudioDevice]
    let volume: Float
    let muted: Bool
}

/// Orchestrates multiple `RoutedSource`s — one per source — so several apps
/// can each play to their own destination(s) at the same time.
///
/// All Core Audio work runs on a private serial queue so the UI never blocks.
final class AudioEngine: @unchecked Sendable {

    private var sources: [SourceKey: RoutedSource] = [:]
    private let queue = DispatchQueue(label: "com.soundsplitter.engine", qos: .userInitiated)

    /// Reconcile the running routes to exactly match `plans`.
    func sync(_ plans: [SourcePlan], onFailure: @escaping (SourceKey, String) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            let desiredKeys = Set(plans.map(\.key))

            // Tear down sources no longer wanted.
            for key in Array(self.sources.keys) where !desiredKeys.contains(key) {
                self.sources[key]?.stop()
                self.sources[key] = nil
            }

            for plan in plans {
                let routed: RoutedSource
                if let existing = self.sources[plan.key] {
                    routed = existing
                } else {
                    routed = RoutedSource(key: plan.key, source: plan.source)
                    self.sources[plan.key] = routed
                }

                routed.setVolume(plan.volume, muted: plan.muted)
                if !routed.setOutputs(plan.outputs) {
                    routed.stop()
                    self.sources[plan.key] = nil
                    onFailure(plan.key,
                              "No se pudo enrutar el audio. Revisa el permiso de grabación de audio en Ajustes → Privacidad y seguridad.")
                }
            }
        }
    }

    func stopAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sources.values.forEach { $0.stop() }
            self.sources.removeAll()
        }
    }
}

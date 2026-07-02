import Foundation
import Darwin

/// Freeze detection + crash capture, all written to the log file so problems
/// are diagnosable after they happen (see `Log.fileURL`).
enum Diagnostics {

    /// Install everything. Call once at launch.
    static func install() {
        logBanner()
        installCrashHandlers()
        MainThreadWatchdog.shared.start()
    }

    private static func logBanner() {
        Log.info("——— SoundSplitter launched (pid \(getpid())) ———")
        Log.info("Log file: \(Log.fileURL.path)")
    }

    // MARK: Crash handlers

    private static func installCrashHandlers() {
        // Uncaught Objective-C / Swift NSExceptions.
        // This closure becomes a C function pointer, so it must not capture
        // any context — only global/static references are allowed.
        NSSetUncaughtExceptionHandler { exception in
            let stack = exception.callStackSymbols.joined(separator: "\n")
            let now = ISO8601DateFormatter().string(from: Date())
            Log.appendSync("\(now) [CRASH] Uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "")\n\(stack)\n")
        }

        // Fatal POSIX signals (segfault, abort, etc.).
        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGTRAP] {
            signal(sig) { received in
                // Keep this minimal and async-signal-safe-ish. callStackSymbols
                // is not strictly signal-safe but is our best effort to capture
                // where things died before re-raising the default handler.
                let frames = Thread.callStackSymbols.joined(separator: "\n")
                Log.appendSync("\n===== FATAL SIGNAL \(received) =====\n\(frames)\n")
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }
}

/// Detects main-thread hangs (the "freeze" the user reported): a background
/// timer bumps a counter that the main thread is expected to reset. If the
/// main thread fails to reset it within the threshold, we log a freeze along
/// with a snapshot of the main thread's stack.
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    /// How long the main thread may be unresponsive before we flag a freeze.
    private let threshold: TimeInterval = 2.0
    private let pingInterval: TimeInterval = 0.5

    private var lastPong = Date()
    private var frozenLogged = false
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let monitorQueue = DispatchQueue(label: "com.soundsplitter.watchdog")

    func start() {
        // Main thread heartbeat: repeatedly mark itself alive.
        scheduleMainPing()

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        self.timer = timer
    }

    private func scheduleMainPing() {
        DispatchQueue.main.async { [weak self] in
            self?.pong()
            // Re-arm on the next runloop pass. If the main thread is blocked,
            // this simply won't run, and `lastPong` goes stale.
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.pong()
            }
        }
    }

    private func pong() {
        lock.lock(); lastPong = Date(); frozenLogged = false; lock.unlock()
    }

    private func check() {
        lock.lock()
        let elapsed = Date().timeIntervalSince(lastPong)
        let alreadyLogged = frozenLogged
        if elapsed > threshold && !alreadyLogged { frozenLogged = true }
        lock.unlock()

        guard elapsed > threshold, !alreadyLogged else { return }
        Log.error("FREEZE detectado: el hilo principal lleva \(String(format: "%.1f", elapsed))s sin responder.")
        // Capturing the main thread's stack from here isn't directly possible
        // in pure Swift; we record the app-wide backtrace as a best effort.
        let frames = Thread.callStackSymbols.prefix(20).joined(separator: "\n")
        Log.appendSync("\(ISO8601DateFormatter().string(from: Date())) [FREEZE] watchdog backtrace:\n\(frames)\n")
    }
}

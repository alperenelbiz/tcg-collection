import Foundation
import Synchronization

/// A64: the iPhone's extra time around the library's flush when the app goes to the background. `start` asks the system
/// for it (on iOS `UIApplication.beginBackgroundTask(withName:expirationHandler:)`) and returns its token; `end` gives it
/// back (`endBackgroundTask`). `end` is called exactly once: when `work` ends, or earlier when the expiration handler
/// fires (the time ran out: the task must end there, else iOS kills the app). Pure orchestration with an injected start
/// and end, so the unit tests run it on the Mac. It runs on the caller's actor (approachable concurrency's
/// `nonisolated(nonsending)`); the app calls it on the main actor, where iOS also calls the expiration handler.
nonisolated enum BackgroundSave {
    static func run<Token: Sendable>(
        start: (_ expiration: @escaping @Sendable () -> Void) -> Token,
        end: @escaping @Sendable (Token) -> Void,
        work: () async -> Void
    ) async {
        let once = Once<Token>(end: end)
        let token = start { once.expire() }
        once.started(token)
        await work()
        once.finish()
    }

    /// The token and whether the task has ended, behind one lock: the expiration handler can fire before `start` has
    /// returned the token, during `work`, or after it.
    private final class Once<Token: Sendable>: Sendable {
        private struct State {
            var token: Token?
            var expired = false
            var ended = false

            /// The token to end, once: nil before the token came and after the task ended.
            mutating func takeEnd() -> Token? {
                guard !ended, let token else { return nil }
                ended = true
                return token
            }
        }
        private let state = Mutex(State())
        private let end: @Sendable (Token) -> Void

        init(end: @escaping @Sendable (Token) -> Void) { self.end = end }

        /// The token came: when the time ran out before it, the task ends now.
        func started(_ token: Token) {
            let toEnd = state.withLock { s -> Token? in
                s.token = token
                return s.expired ? s.takeEnd() : nil
            }
            if let toEnd { end(toEnd) }
        }

        /// The time ran out: end the task now if its token is known, else as soon as it comes.
        func expire() {
            let toEnd = state.withLock { s -> Token? in
                s.expired = true
                return s.takeEnd()
            }
            if let toEnd { end(toEnd) }
        }

        /// The work ended.
        func finish() {
            if let toEnd = state.withLock({ $0.takeEnd() }) { end(toEnd) }
        }
    }
}


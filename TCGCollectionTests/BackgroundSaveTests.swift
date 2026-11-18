import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// A64: the iPhone asks iOS for its extra time around the library's flush and ends it exactly once: when the flush ends,
/// or when the time runs out first (Review Focus 1 and 2). The task begins synchronously, before any `Task` hop (Task 1B).
struct BackgroundSaveTests {
    /// What the injected starter and ender saw, in order.
    final class Log: Sendable {
        let events = Mutex<[String]>([])
        let expiration = Mutex<(@Sendable () -> Void)?>(nil)
        func add(_ event: String) { events.withLock { $0.append(event) } }
        var all: [String] { events.withLock { $0 } }
    }

    /// Task 1B: `begin` calls `start` before it returns (no hop), and `finish` ends the task once; an expiration before
    /// `finish` ends it once too.
    @Test func theBackgroundTaskBeginsBeforeTheWork() {
        let log = Log()
        let session = BackgroundSave.begin(
            start: { expiration in
                log.add("start"); log.expiration.withLock { $0 = expiration }; return 7
            },
            end: { token in log.add("end \(token)") })
        #expect(log.all == ["start"])                                   // synchronous: before `begin` returned
        log.add("work")
        session.finish()
        session.finish()
        #expect(log.all == ["start", "work", "end 7"])

        let expired = Log()
        let second = BackgroundSave.begin(
            start: { expiration in
                expired.add("start"); expired.expiration.withLock { $0 = expiration }; return 9
            },
            end: { token in expired.add("end \(token)") })
        expired.expiration.withLock { $0 }?()                           // the time ran out before the flush ended
        second.finish()
        #expect(expired.all == ["start", "end 9"])
    }

    @Test func theTaskEndsAfterTheWork() async {
        let log = Log()
        let session = BackgroundSave.begin(
            start: { expiration in
                log.add("start"); log.expiration.withLock { $0 = expiration }; return 7
            },
            end: { token in log.add("end \(token)") })
        await Task.yield()
        log.add("work")
        session.finish()
        #expect(log.all == ["start", "work", "end 7"])
    }

    @Test func theTaskEndsOnceWhenTimeRunsOut() async {
        let log = Log()
        let session = BackgroundSave.begin(
            start: { expiration in
                log.add("start"); log.expiration.withLock { $0 = expiration }; return 3
            },
            end: { token in log.add("end \(token)") })
        log.add("work begins")
        // iOS calls the expiration handler while the flush still runs: the task ends there, at once.
        log.expiration.withLock { $0 }?()
        log.add("work ends")
        session.finish()
        #expect(log.all == ["start", "work begins", "end 3", "work ends"])
        // A second expiration (or a late one) ends nothing more.
        log.expiration.withLock { $0 }?()
        #expect(log.all.filter { $0.hasPrefix("end") }.count == 1)
    }

    @Test func anExpirationBeforeTheTokenEndsTheTaskOnceTheTokenComes() {
        let log = Log()
        let session = BackgroundSave.begin(
            start: { expiration in
                log.add("start"); expiration(); return 5      // the handler fires before `start` returned its token
            },
            end: { token in log.add("end \(token)") })
        log.add("work")
        session.finish()
        #expect(log.all == ["start", "end 5", "work"])
    }
}

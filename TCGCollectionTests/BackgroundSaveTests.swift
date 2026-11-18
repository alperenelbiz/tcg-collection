import Foundation
import Synchronization
import Testing
@testable import TCGCollection2

/// A64: the iPhone asks iOS for its extra time around the library's flush and ends it exactly once: when the flush ends,
/// or when the time runs out first (Review Focus 1 and 2).
struct BackgroundSaveTests {
    /// What the injected starter and ender saw, in order.
    final class Log: Sendable {
        let events = Mutex<[String]>([])
        let expiration = Mutex<(@Sendable () -> Void)?>(nil)
        func add(_ event: String) { events.withLock { $0.append(event) } }
        var all: [String] { events.withLock { $0 } }
    }

    @Test func theTaskEndsAfterTheWork() async {
        let log = Log()
        await BackgroundSave.run(
            start: { expiration in
                log.add("start"); log.expiration.withLock { $0 = expiration }; return 7
            },
            end: { token in log.add("end \(token)") },
            work: { log.add("work") })
        #expect(log.all == ["start", "work", "end 7"])
    }

    @Test func theTaskEndsOnceWhenTimeRunsOut() async {
        let log = Log()
        await BackgroundSave.run(
            start: { expiration in
                log.add("start"); log.expiration.withLock { $0 = expiration }; return 3
            },
            end: { token in log.add("end \(token)") },
            work: {
                log.add("work begins")
                // iOS calls the expiration handler while the flush still runs: the task ends there, at once.
                let expire = log.expiration.withLock { $0 }
                expire?()
                log.add("work ends")
            })
        #expect(log.all == ["start", "work begins", "end 3", "work ends"])
        // A second expiration (or a late one) ends nothing more.
        log.expiration.withLock { $0 }?()
        #expect(log.all.filter { $0.hasPrefix("end") }.count == 1)
    }

    @Test func anExpirationBeforeTheTokenEndsTheTaskOnceTheTokenComes() async {
        let log = Log()
        await BackgroundSave.run(
            start: { expiration in
                log.add("start"); expiration(); return 5      // the handler fires before `start` returned its token
            },
            end: { token in log.add("end \(token)") },
            work: { log.add("work") })
        #expect(log.all == ["start", "end 5", "work"])
    }
}

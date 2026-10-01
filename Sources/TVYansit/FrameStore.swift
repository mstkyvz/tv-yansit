import Foundation

/// Son JPEG karesini tutar ve yeni kare bekleyen istemcilere dagitir.
/// Her kare bir kez kodlanir, tum istemcilere ayni veri gonderilir.
final class FrameStore {
    typealias Waiter = (Data, UInt64) -> Void

    private let lock = NSLock()
    private var frame: Data?
    private var seq: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    var latest: Data? {
        lock.lock(); defer { lock.unlock() }
        return frame
    }

    func publish(_ data: Data) {
        lock.lock()
        frame = data
        seq &+= 1
        let current = seq
        let pending = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        pending.forEach { $0(data, current) }
    }

    /// `seq`'ten sonraki kareyi verir. Ekran degismezse ScreenCaptureKit yeni kare
    /// gondermez; bu durumda `keepAlive` saniye sonra son kare tekrar gonderilir.
    func next(after seq: UInt64, keepAlive: TimeInterval, _ callback: @escaping Waiter) {
        lock.lock()
        if let frame, self.seq != seq {
            let current = self.seq
            lock.unlock()
            callback(frame, current)
            return
        }
        let id = UUID()
        waiters[id] = callback
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + keepAlive) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let waiter = self.waiters.removeValue(forKey: id)
            let frame = self.frame
            let current = self.seq
            self.lock.unlock()
            guard let waiter else { return }
            if let frame {
                waiter(frame, current)
            } else {
                self.next(after: seq, keepAlive: keepAlive, waiter)
            }
        }
    }
}

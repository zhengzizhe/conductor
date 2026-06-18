import AppKit
@preconcurrency import GhosttyKit

final class GhosttyClipboardBridge: @unchecked Sendable {
    static let shared = GhosttyClipboardBridge()

    private final class ClipboardWriteCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var capturedValue: String?

        func capture(_ value: String) {
            lock.lock()
            capturedValue = value
            lock.unlock()
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return capturedValue
        }
    }

    private let lock = NSLock()
    private var standardClipboardWriteCapture: ClipboardWriteCapture?

    private init() {}

    func writeString(_ string: String, to location: ghostty_clipboard_e) {
        if location == GHOSTTY_CLIPBOARD_STANDARD {
            lock.lock()
            let capture = standardClipboardWriteCapture
            if capture != nil {
                standardClipboardWriteCapture = nil
            }
            lock.unlock()

            if let capture {
                capture.capture(string)
                return
            }
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    @discardableResult
    func captureNextStandardClipboardWrite(_ action: () -> Bool) -> String? {
        let capture = ClipboardWriteCapture()
        lock.lock()
        standardClipboardWriteCapture = capture
        lock.unlock()

        defer {
            lock.lock()
            if standardClipboardWriteCapture === capture {
                standardClipboardWriteCapture = nil
            }
            lock.unlock()
        }

        guard action() else { return nil }
        return capture.value
    }
}

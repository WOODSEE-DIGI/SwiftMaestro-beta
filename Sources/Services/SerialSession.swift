import Foundation

// MARK: - Serial Session
//
// Native USB-serial bridge for the Terminal panel (Arduino, ESP32, CH340,
// FTDI, CP210x, …) — replaces the `screen(1)` subprocess with a direct
// termios link: open(2) the /dev node, configure 8N1 at the requested baud,
// pump reads through a DispatchSource, and let the view write keystrokes
// back down the same descriptor.
//
// Threading: reads fire on a private queue and are handed to the caller via
// `onData`; the caller must hop to the main thread before feeding SwiftTerm.
// `send` may be called from any thread.

final class SerialSession: @unchecked Sendable {

    enum SerialError: LocalizedError {
        case openFailed(String, Int32)
        case unsupportedBaud(Int)

        var errorDescription: String? {
            switch self {
            case .openFailed(let path, let code):
                return "Could not open \(path): \(String(cString: strerror(code)))"
            case .unsupportedBaud(let baud):
                return "Baud rate \(baud) is not supported by the native serial link."
            }
        }
    }

    /// Supported baud rates (mapped to termios speed constants).
    static let supportedBauds: [Int] = [9600, 19200, 38400, 57600, 115200, 230400]

    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.woodseedigi.swiftmaestro.serial", qos: .userInitiated)
    private let onData: ([UInt8]) -> Void

    /// Open and configure the serial device, then start the read pump.
    init(device: String, baud: Int, onData: @escaping ([UInt8]) -> Void) throws {
        self.onData = onData

        guard let speed = Self.termiosSpeed(for: baud) else {
            throw SerialError.unsupportedBaud(baud)
        }

        // O_NONBLOCK so the read source drains with read() returning EAGAIN
        // instead of stalling the queue; O_NOCTTY so the board never becomes
        // our controlling terminal.
        let handle = open(device, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard handle >= 0 else {
            throw SerialError.openFailed(device, errno)
        }
        fd = handle

        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)   // ignore modem lines, enable receiver
        options.c_cflag &= ~tcflag_t(PARENB)          // no parity
        options.c_cflag &= ~tcflag_t(CSTOPB)          // 1 stop bit
        options.c_cflag &= ~tcflag_t(CSIZE)
        options.c_cflag |= tcflag_t(CS8)              // 8 data bits
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)
        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.pump()
        }
        source.setCancelHandler { [fd] in
            Darwin.close(fd)
        }
        readSource = source
        source.resume()
    }

    /// Write bytes to the board.
    func send(_ bytes: [UInt8]) {
        guard fd >= 0, !bytes.isEmpty else { return }
        bytes.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var remaining = ptr.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written <= 0 { break }
                offset += written
                remaining -= written
            }
        }
    }

    /// End the session and release the device node.
    func close() {
        readSource?.cancel()
        readSource = nil
        fd = -1
    }

    deinit {
        close()
    }

    // MARK: - Internals

    private func pump() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.read(fd, base, ptr.count)
        }
        guard count > 0 else { return }
        onData(Array(buffer[0..<count]))
    }

    private static func termiosSpeed(for baud: Int) -> speed_t? {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }
}

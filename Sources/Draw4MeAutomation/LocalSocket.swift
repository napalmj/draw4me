import Foundation
import Darwin

/// Transport between the running app and local automation clients (the MCP relay).
///
/// Security model: a Unix domain socket (no TCP, nothing reachable from the network) inside a
/// per-user directory with mode 0700, socket mode 0600, and every connection's peer uid checked
/// with `getpeereid` — only processes running as the same user can talk to the app. Frames are
/// newline-delimited JSON `AutomationRequest`s / `AutomationResponse`s with a size cap.
public enum LocalSocket {
    public static let maxFrameBytes = AutomationEndpoint.maxRequestBytes
    /// Responses can carry a base64 PNG, so allow more on the way back.
    public static let maxResponseBytes = 64 * 1024 * 1024

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Draw4Me", isDirectory: true)
    }

    /// `DRAW4ME_SOCKET` overrides the path (tests, multiple instances).
    public static var defaultPath: String {
        ProcessInfo.processInfo.environment["DRAW4ME_SOCKET"] ?? defaultDirectory.appendingPathComponent("agent.sock").path
    }

    public enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String), unsafeDirectory(String), unsafeSocket(String), system(String, Int32), notRunning, timeout, frameTooLarge, closed
        public var description: String {
            switch self {
            case .pathTooLong(let p): return "Socket path is too long: \(p)"
            case .unsafeDirectory(let p): return "Refusing to use \(p): it must be a directory owned by you with no access for others"
            case .unsafeSocket(let p): return "Refusing to connect to \(p): it is not a socket owned by you"
            case .system(let what, let e): return "\(what) failed: \(String(cString: strerror(e)))"
            case .notRunning: return "The draw4me app is not running (no socket)"
            case .timeout: return "Timed out waiting for the draw4me app"
            case .frameTooLarge: return "Message too large"
            case .closed: return "Connection closed"
            }
        }
    }

    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Creates the directory if needed and checks it is ours and private (not a symlink, mode 0700).
    static func prepareDirectory(_ dir: String) throws {
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard mkdir(dir, 0o700) == 0 || errno == EEXIST else { throw SocketError.system("mkdir \(dir)", errno) }
            guard lstat(dir, &st) == 0 else { throw SocketError.system("lstat \(dir)", errno) }
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { throw SocketError.unsafeDirectory(dir) }
        if (st.st_mode & 0o077) != 0 { guard chmod(dir, 0o700) == 0 else { throw SocketError.unsafeDirectory(dir) } }
    }

    /// Checks that `path` is a socket owned by the current user.
    static func isOwnSocket(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFSOCK && st.st_uid == getuid()
    }

    static func setTimeouts(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw errno == EAGAIN ? SocketError.timeout : SocketError.system("write", errno)
                }
                off += n
            }
        }
    }
}

/// Reads newline-delimited frames from a file descriptor with a size cap.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    private let limit: Int

    init(fd: Int32, limit: Int) { self.fd = fd; self.limit = limit }

    /// Next frame without its newline, or nil at end of stream.
    func next() throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                return Data(line)
            }
            if buffer.count > limit { throw LocalSocket.SocketError.frameTooLarge }
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return buffer.isEmpty ? nil : { let b = buffer; buffer = Data(); return b }() }
            if n < 0 {
                if errno == EINTR { continue }
                throw errno == EAGAIN ? LocalSocket.SocketError.timeout : LocalSocket.SocketError.system("read", errno)
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// The app side: accepts same-user connections and answers each request by calling `handler`
/// on the main thread (where the document editor lives).
public final class LocalSocketServer {
    public let path: String
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "draw4me.socket.accept")
    private let handler: (Data) -> Data
    private let handlerQueue: DispatchQueue
    private let lock = NSLock()
    private var connections = 0
    public static let maxConnections = 8
    /// Idle connections are closed after this many seconds without a request.
    public static let idleTimeout = 600

    /// `handler` maps request bytes to response bytes; it is called on `handlerQueue` (default: main).
    public init(path: String = LocalSocket.defaultPath, handlerQueue: DispatchQueue = .main, handler: @escaping (Data) -> Data) {
        self.path = path
        self.handlerQueue = handlerQueue
        self.handler = handler
    }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try LocalSocket.prepareDirectory(dir)
        // Remove a stale socket from a previous run, but only if it's our own socket file.
        var st = stat()
        if lstat(path, &st) == 0 {
            guard LocalSocket.isOwnSocket(path) else { throw LocalSocket.SocketError.unsafeSocket(path) }
            if let probe = try? LocalSocketClient.connect(path: path, timeout: 1) {
                probe.close()
                throw LocalSocket.SocketError.system("Another draw4me instance is already listening on \(path); bind", EADDRINUSE)
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalSocket.SocketError.system("socket", errno) }
        var addr = try LocalSocket.makeAddress(path)
        // Create the socket file with no access for anyone else, then tighten to 0600.
        let oldMask = umask(0o177)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(oldMask)
        guard rc == 0 else { let e = errno; Darwin.close(fd); throw LocalSocket.SocketError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { let e = errno; Darwin.close(fd); unlink(path); throw LocalSocket.SocketError.system("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        source = src
    }

    public func stop() {
        source?.cancel(); source = nil
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        if LocalSocket.isOwnSocket(path) { unlink(path) }
    }

    deinit { stop() }

    private func acceptPending() {
        while true {
            let cfd = accept(listenFD, nil, nil)
            if cfd < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(cfd, &uid, &gid) == 0, uid == getuid() else { Darwin.close(cfd); continue }
            lock.lock()
            let allowed = connections < Self.maxConnections
            if allowed { connections += 1 }
            lock.unlock()
            guard allowed else { Darwin.close(cfd); continue }
            _ = fcntl(cfd, F_SETFL, fcntl(cfd, F_GETFL) & ~O_NONBLOCK)
            LocalSocket.setTimeouts(cfd, seconds: Self.idleTimeout)
            Thread.detachNewThread { [weak self] in self?.serve(cfd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            Darwin.close(fd)
            lock.lock(); connections -= 1; lock.unlock()
        }
        let reader = LineReader(fd: fd, limit: LocalSocket.maxFrameBytes)
        while true {
            let frame: Data
            do {
                guard let f = try reader.next() else { return }
                frame = f
            } catch LocalSocket.SocketError.frameTooLarge {
                let r = AutomationEndpoint.encode(AutomationResponse(ok: false, error: "Request too large", errorCode: "limitExceeded"))
                try? LocalSocket.writeAll(fd, r + Data([0x0A]))
                return
            } catch { return }
            if frame.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) { continue }
            let handler = self.handler
            let response = handlerQueue.sync { handler(frame) }
            do { try LocalSocket.writeAll(fd, response + Data([0x0A])) } catch { return }
        }
    }
}

/// The client side (used by the MCP relay): one connection, request/response.
public final class LocalSocketClient {
    private var fd: Int32
    private let reader: LineReader
    public let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd; self.path = path
        reader = LineReader(fd: fd, limit: LocalSocket.maxResponseBytes)
    }

    /// Connects to the app. Throws `.notRunning` when there is no socket or nobody is listening.
    public static func connect(path: String = LocalSocket.defaultPath, timeout: Int = 120) throws -> LocalSocketClient {
        var st = stat()
        guard lstat(path, &st) == 0 else { throw LocalSocket.SocketError.notRunning }
        guard LocalSocket.isOwnSocket(path) else { throw LocalSocket.SocketError.unsafeSocket(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalSocket.SocketError.system("socket", errno) }
        var addr = try LocalSocket.makeAddress(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            if e == ECONNREFUSED || e == ENOENT { throw LocalSocket.SocketError.notRunning }
            throw LocalSocket.SocketError.system("connect", e)
        }
        LocalSocket.setTimeouts(fd, seconds: timeout)
        return LocalSocketClient(fd: fd, path: path)
    }

    public func send(_ request: Data) throws -> Data {
        guard fd >= 0 else { throw LocalSocket.SocketError.closed }
        guard request.count <= LocalSocket.maxFrameBytes else { throw LocalSocket.SocketError.frameTooLarge }
        // JSONEncoder output never contains raw newlines, so a newline safely ends the frame.
        try LocalSocket.writeAll(fd, request + Data([0x0A]))
        guard let line = try reader.next() else { close(); throw LocalSocket.SocketError.closed }
        return line
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}

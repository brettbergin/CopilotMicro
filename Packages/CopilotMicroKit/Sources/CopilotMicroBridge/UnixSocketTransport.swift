import CopilotMicroCore
import Darwin
import Dispatch
import Foundation

public enum IPCTransportError: Error, Equatable, Sendable {
    case pathTooLong
    case invalidPath
    case addressInUse
    case permissionDenied
    case peerMismatch
    case timedOut
    case disconnected
    case ioFailure
    case protocolViolation
    case wrongRole
    case staleGeneration
    case staleSequence
    case sequenceGap
    case registrationRejected(IPCRegistrationRejectionCode)
}

public enum UnixSocketPath {
    public static let maximumBytes = 103

    public static func validate(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix("/") else {
            throw IPCTransportError.invalidPath
        }
        guard !path.utf8.contains(0), path.utf8.count <= maximumBytes else {
            throw IPCTransportError.pathTooLong
        }
    }
}

public final class UnixSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        try configureSocket(descriptor)
    }

    deinit {
        close()
    }

    public static func connect(
        to socketURL: URL,
        timeoutMilliseconds: Int32 = 2_000
    ) throws -> UnixSocketConnection {
        try UnixSocketPath.validate(socketURL)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw IPCTransportError.ioFailure
        }
        do {
            try configureSocket(descriptor)
            let deadline = try deadlineNanoseconds(timeoutMilliseconds: timeoutMilliseconds)
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw IPCTransportError.ioFailure
            }
            var address = try unixAddress(for: socketURL.path)
            let addressLength = unixAddressLength(address)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength)
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else {
                    throw IPCTransportError.ioFailure
                }
                try wait(
                    for: Int16(POLLOUT),
                    descriptor: descriptor,
                    timeoutMilliseconds: try remainingMilliseconds(until: deadline)
                )
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                guard
                    getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &socketErrorLength
                    ) == 0,
                    socketError == 0
                else {
                    throw IPCTransportError.ioFailure
                }
            }
            guard fcntl(descriptor, F_SETFL, flags) == 0 else {
                throw IPCTransportError.ioFailure
            }
            return try UnixSocketConnection(descriptor: descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    public var peerEffectiveUserID: uid_t {
        get throws {
            try withDescriptor { descriptor in
                var userID: uid_t = 0
                var groupID: gid_t = 0
                guard getpeereid(descriptor, &userID, &groupID) == 0 else {
                    throw IPCTransportError.ioFailure
                }
                return userID
            }
        }
    }

    public func writeMessage(
        _ payload: Data,
        timeoutMilliseconds: Int32 = 2_000
    ) throws {
        let framed = try LengthPrefixedFraming.encode(payload)
        try withDescriptor { descriptor in
            try writeAll(
                framed,
                descriptor: descriptor,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
    }

    public func readMessage(timeoutMilliseconds: Int32 = 2_000) throws -> Data {
        try withDescriptor { descriptor in
            let deadline = try deadlineNanoseconds(timeoutMilliseconds: timeoutMilliseconds)
            let header = try readExactly(
                count: 4,
                descriptor: descriptor,
                deadlineNanoseconds: deadline
            )
            let length = header.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0 else {
                throw IPCTransportError.protocolViolation
            }
            guard length <= LengthPrefixedFraming.maximumPayloadBytes else {
                throw IPCTransportError.protocolViolation
            }
            return try readExactly(
                count: Int(length),
                descriptor: descriptor,
                deadlineNanoseconds: deadline
            )
        }
    }

    public func close() {
        lock.lock()
        let activeDescriptor = descriptor
        descriptor = -1
        lock.unlock()
        if activeDescriptor >= 0 {
            Darwin.close(activeDescriptor)
        }
    }

    private func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard descriptor >= 0 else {
            throw IPCTransportError.disconnected
        }
        return try body(descriptor)
    }
}

public final class UnixSocketListener: @unchecked Sendable {
    public let socketURL: URL

    private let lock = NSLock()
    private let fileManager: FileManager
    private var descriptor: Int32 = -1
    private var socketIdentity: FileIdentity?

    public init(socketURL: URL, fileManager: FileManager = .default) throws {
        try UnixSocketPath.validate(socketURL)
        self.socketURL = socketURL.standardizedFileURL
        self.fileManager = fileManager
    }

    deinit {
        close()
    }

    public func start(backlog: Int32 = 8) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard descriptor < 0 else {
            return
        }
        guard backlog > 0, backlog <= 64 else {
            throw IPCTransportError.invalidPath
        }
        let directory = socketURL.deletingLastPathComponent()
        try preparePrivateDirectory(directory, fileManager: fileManager)
        guard try fileIdentity(at: socketURL) == nil else {
            throw IPCTransportError.addressInUse
        }

        let newDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard newDescriptor >= 0 else {
            throw IPCTransportError.ioFailure
        }
        var createdIdentity: FileIdentity?
        do {
            try configureSocket(newDescriptor)
            var address = try unixAddress(for: socketURL.path)
            let addressLength = unixAddressLength(address)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(newDescriptor, $0, addressLength)
                }
            }
            guard bindResult == 0 else {
                throw IPCTransportError.ioFailure
            }
            createdIdentity = try fileIdentity(at: socketURL)
            guard createdIdentity != nil else {
                throw IPCTransportError.ioFailure
            }
            guard chmod(socketURL.path, 0o600) == 0 else {
                throw IPCTransportError.permissionDenied
            }
            guard Darwin.listen(newDescriptor, backlog) == 0 else {
                throw IPCTransportError.ioFailure
            }
            descriptor = newDescriptor
            socketIdentity = createdIdentity
        } catch {
            Darwin.close(newDescriptor)
            if let createdIdentity,
                let currentIdentity = try? fileIdentity(at: socketURL),
                currentIdentity == createdIdentity
            {
                _ = unlink(socketURL.path)
            }
            throw error
        }
    }

    public func accept(timeoutMilliseconds: Int32 = 2_000) throws -> UnixSocketConnection {
        try withDescriptor { descriptor in
            try wait(
                for: Int16(POLLIN),
                descriptor: descriptor,
                timeoutMilliseconds: timeoutMilliseconds
            )
            let accepted = Darwin.accept(descriptor, nil, nil)
            guard accepted >= 0 else {
                throw IPCTransportError.ioFailure
            }
            do {
                return try UnixSocketConnection(descriptor: accepted)
            } catch {
                Darwin.close(accepted)
                throw error
            }
        }
    }

    public func close() {
        lock.lock()
        let activeDescriptor = descriptor
        descriptor = -1
        let ownedIdentity = socketIdentity
        socketIdentity = nil
        lock.unlock()

        if activeDescriptor >= 0 {
            Darwin.close(activeDescriptor)
        }
        guard let ownedIdentity,
            let currentIdentity = try? fileIdentity(at: socketURL),
            currentIdentity == ownedIdentity
        else {
            return
        }
        _ = unlink(socketURL.path)
    }

    private func withDescriptor<T>(_ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard descriptor >= 0 else {
            throw IPCTransportError.disconnected
        }
        return try body(descriptor)
    }
}

public final class AuthenticatedIPCConnection: @unchecked Sendable {
    public let connectionID: IPCConnectionID
    public let generation: ConnectionGeneration
    public let localRole: IPCPeerRole
    public let registration: IPCRegistration

    private let socket: UnixSocketConnection
    private let lock = NSLock()
    private var nextOutgoingSequence: UInt64 = 1
    private var incomingSequence: IPCSequenceTracker
    private var inFlight = IPCInFlightRequestTracker()
    private var isConnected = true

    init(
        socket: UnixSocketConnection,
        connectionID: IPCConnectionID,
        registration: IPCRegistration,
        localRole: IPCPeerRole
    ) {
        self.socket = socket
        self.connectionID = connectionID
        self.generation = registration.generation
        self.registration = registration
        self.localRole = localRole
        incomingSequence = IPCSequenceTracker(generation: registration.generation)
    }

    public func send(
        payload: Data,
        timeoutMilliseconds: Int32 = 2_000
    ) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard isConnected else {
            throw IPCTransportError.disconnected
        }
        let frame = try IPCFrame(
            role: localRole,
            generation: generation,
            sequence: nextOutgoingSequence,
            payload: payload
        )
        let receiverRole: IPCPeerRole = localRole == .nativeApp ? .cliBridge : .nativeApp
        guard IPCDirectionValidator.validate(frame, receiverRole: receiverRole) == .allowed else {
            throw IPCTransportError.wrongRole
        }
        try socket.writeMessage(frame.encoded(), timeoutMilliseconds: timeoutMilliseconds)
        nextOutgoingSequence += 1
    }

    public func receive(timeoutMilliseconds: Int32 = 2_000) throws -> IPCFrame {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard isConnected else {
            throw IPCTransportError.disconnected
        }
        let data = try socket.readMessage(timeoutMilliseconds: timeoutMilliseconds)
        let frame: IPCFrame
        do {
            frame = try IPCFrameCodec.decode(data)
        } catch {
            invalidateLocked()
            throw IPCTransportError.protocolViolation
        }
        guard IPCDirectionValidator.validate(frame, receiverRole: localRole) == .allowed else {
            invalidateLocked()
            throw IPCTransportError.wrongRole
        }
        switch incomingSequence.accept(frame) {
        case .accepted:
            return frame
        case .staleGeneration:
            invalidateLocked()
            throw IPCTransportError.staleGeneration
        case .staleSequence:
            invalidateLocked()
            throw IPCTransportError.staleSequence
        case .sequenceGap:
            invalidateLocked()
            throw IPCTransportError.sequenceGap
        }
    }

    public func beginRequest(_ requestID: RequestID) throws {
        lock.lock()
        defer {
            lock.unlock()
        }
        guard isConnected else {
            throw IPCTransportError.disconnected
        }
        switch inFlight.begin(requestID) {
        case .accepted:
            return
        case .invalidRequest:
            throw IPCTransportError.protocolViolation
        case .duplicateRequest:
            throw IPCTransportError.protocolViolation
        case .tooManyInFlight:
            throw IPCTransportError.protocolViolation
        }
    }

    @discardableResult
    public func completeRequest(_ requestID: RequestID) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }
        return inFlight.complete(requestID)
    }

    public func close() {
        lock.lock()
        invalidateLocked()
        lock.unlock()
    }

    private func invalidateLocked() {
        guard isConnected else {
            return
        }
        isConnected = false
        inFlight.invalidate()
        socket.close()
    }
}

public final class AuthenticatedIPCServer: @unchecked Sendable {
    private let listener: UnixSocketListener
    private let authenticator: IPCAuthenticator

    public init(socketURL: URL, bootstrapToken: IPCBootstrapToken) throws {
        listener = try UnixSocketListener(socketURL: socketURL)
        authenticator = IPCAuthenticator(
            expectedToken: bootstrapToken,
            expectedUserID: geteuid()
        )
    }

    public func start() throws {
        try listener.start()
    }

    public func accept(timeoutMilliseconds: Int32 = 2_000) throws -> AuthenticatedIPCConnection {
        let deadline = try deadlineNanoseconds(timeoutMilliseconds: timeoutMilliseconds)
        let socket = try listener.accept(
            timeoutMilliseconds: try remainingMilliseconds(until: deadline)
        )
        do {
            guard try socket.peerEffectiveUserID == authenticator.expectedUserID else {
                throw IPCTransportError.peerMismatch
            }
            let registrationData = try socket.readMessage(
                timeoutMilliseconds: try remainingMilliseconds(until: deadline)
            )
            let registration: IPCRegistration
            do {
                registration = try IPCRegistrationCodec.decode(registrationData)
            } catch {
                let rejection = try IPCRegistrationResult.rejected(code: .protocolViolation)
                try? socket.writeMessage(
                    IPCRegistrationResultCodec.encode(rejection),
                    timeoutMilliseconds: try remainingMilliseconds(until: deadline)
                )
                throw IPCTransportError.protocolViolation
            }
            let authentication = authenticator.authenticate(
                registration,
                peerUserID: try socket.peerEffectiveUserID
            )
            guard authentication == .accepted else {
                let rejectionCode: IPCRegistrationRejectionCode
                switch authentication {
                case .invalidToken:
                    rejectionCode = .invalidToken
                case .wrongPeer:
                    rejectionCode = .wrongPeer
                case .wrongRole:
                    rejectionCode = .wrongRole
                case .accepted:
                    throw IPCTransportError.protocolViolation
                }
                let rejection = try IPCRegistrationResult.rejected(code: rejectionCode)
                try socket.writeMessage(
                    IPCRegistrationResultCodec.encode(rejection),
                    timeoutMilliseconds: try remainingMilliseconds(until: deadline)
                )
                throw IPCTransportError.registrationRejected(rejectionCode)
            }
            let connectionID = try IPCConnectionID(
                rawValue: "connection-\(UUID().uuidString.lowercased())"
            )
            let accepted = try IPCRegistrationResult.accepted(connectionID: connectionID)
            try socket.writeMessage(
                IPCRegistrationResultCodec.encode(accepted),
                timeoutMilliseconds: try remainingMilliseconds(until: deadline)
            )
            return AuthenticatedIPCConnection(
                socket: socket,
                connectionID: connectionID,
                registration: registration,
                localRole: .nativeApp
            )
        } catch {
            socket.close()
            throw error
        }
    }

    public func close() {
        listener.close()
    }
}

public enum AuthenticatedIPCClient {
    public static func connect(
        socketURL: URL,
        registration: IPCRegistration,
        timeoutMilliseconds: Int32 = 2_000
    ) throws -> AuthenticatedIPCConnection {
        let deadline = try deadlineNanoseconds(timeoutMilliseconds: timeoutMilliseconds)
        let socket = try UnixSocketConnection.connect(
            to: socketURL,
            timeoutMilliseconds: try remainingMilliseconds(until: deadline)
        )
        do {
            guard try socket.peerEffectiveUserID == geteuid() else {
                throw IPCTransportError.peerMismatch
            }
            try socket.writeMessage(
                IPCRegistrationCodec.encode(registration),
                timeoutMilliseconds: try remainingMilliseconds(until: deadline)
            )
            let result = try IPCRegistrationResultCodec.decode(
                socket.readMessage(
                    timeoutMilliseconds: try remainingMilliseconds(until: deadline)
                )
            )
            guard result.outcome == .accepted, let connectionID = result.connectionID else {
                throw IPCTransportError.registrationRejected(
                    result.code ?? .protocolViolation
                )
            }
            return AuthenticatedIPCConnection(
                socket: socket,
                connectionID: connectionID,
                registration: registration,
                localRole: .cliBridge
            )
        } catch {
            socket.close()
            throw error
        }
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let isSocket: Bool

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        isSocket = value.st_mode.isSocket
    }
}

extension mode_t {
    fileprivate var isSocket: Bool {
        self & S_IFMT == S_IFSOCK
    }
}

private func fileIdentity(at url: URL) throws -> FileIdentity? {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
        if errno == ENOENT {
            return nil
        }
        throw IPCTransportError.ioFailure
    }
    return FileIdentity(value)
}

private func preparePrivateDirectory(_ url: URL, fileManager: FileManager) throws {
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        guard isDirectory.boolValue, values.isSymbolicLink != true, owner == geteuid() else {
            throw IPCTransportError.permissionDenied
        }
    } else {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private func configureSocket(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    guard
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0,
        fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0
    else {
        throw IPCTransportError.ioFailure
    }
}

private func unixAddress(for path: String) throws -> sockaddr_un {
    try UnixSocketPath.validate(URL(fileURLWithPath: path))
    var address = sockaddr_un()
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
        throw IPCTransportError.pathTooLong
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + bytes.count)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        for (index, byte) in bytes.enumerated() {
            destination[index] = UInt8(bitPattern: byte)
        }
    }
    return address
}

private func unixAddressLength(_ address: sockaddr_un) -> socklen_t {
    socklen_t(address.sun_len)
}

private func wait(
    for events: Int16,
    descriptor: Int32,
    timeoutMilliseconds: Int32
) throws {
    var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
    let result = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
    guard result > 0 else {
        throw result == 0 ? IPCTransportError.timedOut : IPCTransportError.ioFailure
    }
    if pollDescriptor.revents & events != 0 {
        return
    }
    let failures = Int16(POLLERR | POLLHUP | POLLNVAL)
    guard pollDescriptor.revents & failures == 0 else {
        throw IPCTransportError.disconnected
    }
    throw IPCTransportError.ioFailure
}

private func readExactly(
    count: Int,
    descriptor: Int32,
    deadlineNanoseconds: UInt64
) throws -> Data {
    var result = Data()
    result.reserveCapacity(count)
    while result.count < count {
        try wait(
            for: Int16(POLLIN),
            descriptor: descriptor,
            timeoutMilliseconds: try remainingMilliseconds(until: deadlineNanoseconds)
        )
        var buffer = [UInt8](repeating: 0, count: min(8_192, count - result.count))
        let received = buffer.withUnsafeMutableBytes {
            Darwin.recv(descriptor, $0.baseAddress, $0.count, 0)
        }
        guard received > 0 else {
            throw received == 0 ? IPCTransportError.disconnected : IPCTransportError.ioFailure
        }
        result.append(contentsOf: buffer.prefix(received))
    }
    return result
}

private func writeAll(
    _ data: Data,
    descriptor: Int32,
    timeoutMilliseconds: Int32
) throws {
    var written = 0
    let deadline = try deadlineNanoseconds(timeoutMilliseconds: timeoutMilliseconds)
    try data.withUnsafeBytes { bytes in
        while written < data.count {
            try wait(
                for: Int16(POLLOUT),
                descriptor: descriptor,
                timeoutMilliseconds: try remainingMilliseconds(until: deadline)
            )
            let sent = Darwin.send(
                descriptor,
                bytes.baseAddress?.advanced(by: written),
                data.count - written,
                0
            )
            guard sent > 0 else {
                throw IPCTransportError.ioFailure
            }
            written += sent
        }
    }
}

private func deadlineNanoseconds(timeoutMilliseconds: Int32) throws -> UInt64 {
    guard timeoutMilliseconds > 0 else {
        throw IPCTransportError.timedOut
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let duration = UInt64(timeoutMilliseconds) * 1_000_000
    let (deadline, overflow) = now.addingReportingOverflow(duration)
    guard !overflow else {
        throw IPCTransportError.timedOut
    }
    return deadline
}

private func remainingMilliseconds(until deadlineNanoseconds: UInt64) throws -> Int32 {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadlineNanoseconds else {
        throw IPCTransportError.timedOut
    }
    let remainingNanoseconds = deadlineNanoseconds - now
    let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
    return Int32(min(roundedMilliseconds, UInt64(Int32.max)))
}

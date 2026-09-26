import CopilotMicroCore
import Dispatch
import Foundation

public enum SessionBridgeAssociationOutcome: String, Equatable, Sendable {
    case notRequested
    case pending
    case bound
    case reconnected
    case tokenClaimedByAnotherInstance
    case unknownToken
}

public enum SessionBridgeRuntimeFailure: String, Error, Equatable, Sendable {
    case alreadyStarted
    case bootstrapUnavailable
    case listenerUnavailable
}

public enum SessionBridgeRuntimeEvent: Equatable, Sendable {
    case listening
    case registrationAccepted(
        activation: SessionBridgeActivation,
        association: SessionBridgeAssociationOutcome
    )
    case sessionUpdated(SessionBridgeUpdate)
    case disconnected
    case connectionFailed
    case failed(SessionBridgeRuntimeFailure)
    case stopped
}

public struct SessionBridgeRuntimeConfiguration: Equatable, Sendable {
    public let rootURL: URL
    public let directoryURL: URL
    public let socketURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        directoryURL = self.rootURL.appendingPathComponent(
            IPCBridgeRuntime.directoryName,
            isDirectory: true
        )
        socketURL = directoryURL.appendingPathComponent(IPCBridgeRuntime.socketFilename)
    }
}

public final class SessionBridgeRuntime: @unchecked Sendable {
    public typealias AssociationHandler =
        @Sendable (IPCRegistration) async -> SessionBridgeAssociationOutcome
    public typealias EventHandler = @Sendable (SessionBridgeRuntimeEvent) async -> Void

    private let lock = NSLock()
    private var startIdentifier: UUID?
    private var server: AuthenticatedIPCServer?
    private var worker: Task<Void, Never>?

    public init() {}

    public var isStarted: Bool {
        lock.withLock {
            startIdentifier != nil
        }
    }

    deinit {
        stop()
    }

    public func start(
        rootURL: URL,
        associationHandler: @escaping AssociationHandler,
        eventHandler: @escaping EventHandler
    ) async throws -> SessionBridgeRuntimeConfiguration {
        let startIdentifier = UUID()
        let startAccepted = lock.withLock {
            guard self.startIdentifier == nil else {
                return false
            }
            self.startIdentifier = startIdentifier
            return true
        }
        guard startAccepted else {
            throw SessionBridgeRuntimeFailure.alreadyStarted
        }

        let configuration = SessionBridgeRuntimeConfiguration(rootURL: rootURL)
        let bootstrapToken: IPCBootstrapToken
        do {
            bootstrapToken = try await IPCBootstrapStore(
                rootURL: configuration.rootURL
            ).loadOrCreate()
        } catch {
            clearStartingState(startIdentifier)
            throw SessionBridgeRuntimeFailure.bootstrapUnavailable
        }

        let server: AuthenticatedIPCServer
        do {
            server = try AuthenticatedIPCServer(
                socketURL: configuration.socketURL,
                bootstrapToken: bootstrapToken
            )
            try server.start()
        } catch {
            clearStartingState(startIdentifier)
            throw SessionBridgeRuntimeFailure.listenerUnavailable
        }

        let serverInstalled = lock.withLock {
            guard self.startIdentifier == startIdentifier else {
                return false
            }
            self.server = server
            return true
        }
        guard serverInstalled else {
            server.close()
            await eventHandler(.stopped)
            return configuration
        }

        await eventHandler(.listening)
        let workerInstalled = lock.withLock {
            guard self.startIdentifier == startIdentifier, self.server === server else {
                return false
            }
            let worker = Task.detached { [self] in
                await Self.run(
                    server: server,
                    associationHandler: associationHandler,
                    eventHandler: eventHandler
                )
                workerDidFinish(
                    startIdentifier: startIdentifier,
                    server: server
                )
            }
            self.worker = worker
            return true
        }
        guard workerInstalled else {
            server.close()
            await eventHandler(.stopped)
            return configuration
        }
        return configuration
    }

    public func stop() {
        let (activeServer, activeWorker) = lock.withLock {
            startIdentifier = nil
            let activeServer = server
            server = nil
            let activeWorker = worker
            worker = nil
            return (activeServer, activeWorker)
        }

        activeWorker?.cancel()
        activeServer?.close()
    }

    private func clearStartingState(_ identifier: UUID) {
        lock.withLock {
            if startIdentifier == identifier {
                startIdentifier = nil
            }
        }
    }

    private static func run(
        server: AuthenticatedIPCServer,
        associationHandler: @escaping AssociationHandler,
        eventHandler: @escaping EventHandler
    ) async {
        defer {
            server.close()
        }
        var reconciler = SessionBridgeReconciler()

        while !Task.isCancelled {
            let connection: AuthenticatedIPCConnection
            do {
                connection = try server.accept(timeoutMilliseconds: 250)
            } catch let error as IPCTransportError {
                if Task.isCancelled {
                    break
                }
                switch error {
                case .timedOut:
                    continue
                case .peerMismatch, .protocolViolation, .wrongRole,
                    .registrationRejected, .disconnected:
                    await eventHandler(.connectionFailed)
                    continue
                case .pathTooLong, .invalidPath, .addressInUse, .permissionDenied,
                    .ioFailure, .staleGeneration, .staleSequence, .sequenceGap:
                    await eventHandler(.failed(.listenerUnavailable))
                    return
                }
            } catch {
                if Task.isCancelled {
                    break
                }
                await eventHandler(.failed(.listenerUnavailable))
                return
            }

            let activation = reconciler.activateAuthenticated(
                connection,
                nowMilliseconds: uptimeMilliseconds()
            )
            if activation == .duplicate {
                await eventHandler(.connectionFailed)
                connection.close()
                continue
            }
            let association = await associationHandler(connection.registration)
            await eventHandler(
                .registrationAccepted(
                    activation: activation,
                    association: association
                )
            )

            var connectionActive = true
            while connectionActive, !Task.isCancelled {
                do {
                    let frame = try connection.receive(timeoutMilliseconds: 250)
                    let update = reconciler.receive(
                        frame,
                        nowMilliseconds: uptimeMilliseconds()
                    )
                    await eventHandler(.sessionUpdated(update))
                } catch IPCTransportError.timedOut {
                    if reconciler.expireIfNeeded(nowMilliseconds: uptimeMilliseconds()) {
                        connectionActive = false
                        await eventHandler(.disconnected)
                    }
                } catch IPCTransportError.disconnected {
                    connectionActive = false
                    reconciler.suspendConnection()
                    await eventHandler(.disconnected)
                } catch {
                    connectionActive = false
                    reconciler.suspendConnection()
                    await eventHandler(.connectionFailed)
                }
            }
            connection.close()
        }

        await eventHandler(.stopped)
    }

    private func workerDidFinish(
        startIdentifier: UUID,
        server: AuthenticatedIPCServer
    ) {
        lock.withLock {
            guard
                self.startIdentifier == startIdentifier,
                self.server === server
            else {
                return
            }
            self.startIdentifier = nil
            self.server = nil
            worker = nil
        }
    }

    private static func uptimeMilliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }
}

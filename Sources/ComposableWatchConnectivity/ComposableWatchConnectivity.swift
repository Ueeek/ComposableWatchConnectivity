//
//  WatchConnectivityService.swift
//  SanpoApp
//
//  Created by KoichiroUeki on 2024/12/06.
//

@preconcurrency import WatchConnectivity
import ComposableArchitecture
import Foundation

public enum WatchConnectivityError: Error, Equatable {
    case sessionNotActive
    case sessionNotReachable
    case other(String)
}

@DependencyClient
public struct WatchConnectivityClient: Sendable {
    public  Action: Equatable {
        case activationDidCompleteWith(WCSessionActivationState)
        case sessionDidBecomeInactive(WCSession)
        case sessionDidDeativate(WCSession)
        case didReceiveMessage([String: Data]?)
        case sendFail(WatchConnectivityError)
    }
    
    public var activate: @Sendable () async -> Void
    public var send: @Sendable((String, Data)) async -> Void
    public var delegate: @Sendable () async -> AsyncStream<Action> = { .never }
}

public extension DependencyValues {
    var watchConnectivityClient: WatchConnectivityClient {
        get { self[WatchConnectivityClient.self] }
        set { self[WatchConnectivityClient.self] = newValue }
    }
}

public extension WatchConnectivityClient: DependencyKey {
    public static let testValue = Self(activate: { fatalError()}, send: { _ in fatalError() }, delegate: { .never })
    public static let liveValue = Self.live
}

public extension WatchConnectivityClient {
    public static var live: Self {
        let task = Task<WatchConnectivitySendableBox, Never> { @MainActor in
            let service = WatchConnectivityService()
            return .init(client: service)
        }
        
        return Self(
            activate: { @MainActor in
                await task.value.client.activate()
            },
            send: { @MainActor key, data in
                await task.value.client.sendData(key: key, data: data)
            },
            delegate: { @MainActor in
                let delegate = await task.value.client
                return AsyncStream { delegate.registerContinuation($0) }
            }
        )
    }
}

private struct WatchConnectivitySendableBox: Sendable {
    @UncheckedSendable var client: WatchConnectivityService
}

final class WatchConnectivityService: NSObject, Sendable, WCSessionDelegate {
    let session: WCSession
    let continuations: LockIsolated<[UUID: AsyncStream<WatchConnectivityClient.Action>.Continuation]>
    init(session: WCSession = .default) {
        self.session = session
        self.continuations = .init([:])
        super.init()
        self.session.delegate = self
    }
    
    func activate() {
        if self.session.activationState == .activated {
            return
        }
        self.session.activate()
    }
    
    func registerContinuation(_ continuation: AsyncStream<WatchConnectivityClient.Action>.Continuation) {
        Task { [continuations] in
            continuations.withValue {
                let id = UUID()
                $0[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    self?.unregisterContinuation(withID: id)
                }
            }
        }
    }
    
    private func unregisterContinuation(withID id: UUID) {
        Task { [continuations] in
            continuations.withValue {
                $0.removeValue(forKey: id)
            }
        }
    }
    
    private func send(_ action: WatchConnectivityClient.Action) {
        Task { [continuations] in
            continuations.withValue {
                $0.values.forEach { $0.yield(action)
                }
            }
        }
    }
    
    func sendData(key: String, data: Data) {
        guard session.activationState == .activated else {
            send(.sendFail(.sessionNotActive))
            return
        }
        
        guard session.isReachable else {
            send(.sendFail(.sessionNotReachable))
            return
        }
        
        Task.detached(priority: .medium) { [self] in
            session.sendMessage([key: data], replyHandler: nil, errorHandler: {[weak self] error in
                self?.send(.sendFail(.other(error.localizedDescription)))
            })
        }
    }
    
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        send(.activationDidCompleteWith(activationState))
    }
    
#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {
        send(.sessionDidBecomeInactive(session))
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        send(.sessionDidDeativate(session))
    }
#endif
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let receivedData = message as? [String: Data]
        send(.didReceiveMessage(receivedData))
    }
    
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(message)
        let receivedData = message as? [String: Data]
        send(.didReceiveMessage(receivedData))
    }
}

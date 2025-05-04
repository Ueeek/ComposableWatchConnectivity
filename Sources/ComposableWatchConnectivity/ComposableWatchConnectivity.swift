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
    public enum Action: Equatable, Sendable {
        case activationDidCompleteWith(WCSessionActivationState)
        case sessionDidBecomeInactive(WCSession)
        case sessionDidDeativate(WCSession)
        case didReceiveMessage([String: Data]?)
        case didReceiveUserInfo([String: Data]?)
        case didReceiveApplicationContext([String: Data]?)
        case sendFail(WatchConnectivityError)
    }
    
    public var activate: @Sendable () async -> Void
    public var sendMessage: @Sendable((String, Data)) async -> Void
    public var transferUserInfo: @Sendable((String, Data)) async -> Void
    public var updateApplicationContext: @Sendable((String, Data)) async -> Void
    public var delegate: @Sendable () async -> AsyncStream<Action> = { .never }
}

extension DependencyValues {
    public var watchConnectivityClient: WatchConnectivityClient {
        get { self[WatchConnectivityClient.self] }
        set { self[WatchConnectivityClient.self] = newValue }
    }
}

extension WatchConnectivityClient: DependencyKey {
    public static let testValue = Self(activate: { fatalError()}, sendMessage: { _ in fatalError() }, transferUserInfo: { _ in fatalError()}, updateApplicationContext: { _ in fatalError() }, delegate: { .never })
    public static let liveValue = Self.live
}

public extension WatchConnectivityClient {
    static var live: Self {
        let task = Task<WatchConnectivitySendableBox, Never> { @MainActor in
            let service = WatchConnectivityService()
            return .init(client: service)
        }
        
        return Self(
            activate: { @MainActor in
                await task.value.client.activate()
            },
            sendMessage: { @MainActor key, data in
                await task.value.client.sendData(key: key, data: data)
            },
            transferUserInfo: { @MainActor key, data in
                await task.value.client.transferUserInfo(key: key, data: data)
            },
            updateApplicationContext: { @MainActor key, data in
                await task.value.client.updateApplicationContext(key: key, data: data)
            }
            ,
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
                $0.values.forEach { $0.yield(action) }
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
    
    func transferUserInfo(key: String, data: Data) {
        guard session.activationState == .activated else {
            send(.sendFail(.sessionNotActive))
            return
        }
        
        Task.detached(priority: .medium) { [self] in
            session.transferUserInfo([key: data])
        }
    }
    
    func updateApplicationContext(key: String, data: Data) {
        guard session.activationState == .activated else {
            send(.sendFail(.sessionNotActive))
            return
        }
        
        Task.detached(priority: .medium) { [self] in
            do {
                try session.updateApplicationContext([key: data])
            } catch (let error) {
                send(.sendFail(.other(error.localizedDescription)))
            }
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
    
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any]) {
        let receivedData = userInfo as? [String: Data]
        send(.didReceiveUserInfo(receivedData))
    }
    
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        let receivedData = applicationContext as? [String: Data]
        send(.didReceiveApplicationContext(receivedData))
    }
}

//
//  GBAWirelessManager.swift
//  GBADeltaCore
//
//  Created for mGBA Wireless Adapter (RFU) Online Relay Support.
//

import Foundation

public final class GBAWirelessManager: NSObject, ObservableObject {
    public static let shared = GBAWirelessManager()
    
    public enum Role: String, CaseIterable, Identifiable {
        case host = "Host"
        case join = "Join"
        
        public var id: String { rawValue }
    }
    
    public enum State: Equatable {
        case disconnected
        case connecting
        case hostListening
        case joinerProbing(probesSent: Int)
        case connected(sessionId: UInt64)
        case error(String)
        
        public var description: String {
            switch self {
            case .disconnected:
                return NSLocalizedString("Disconnected", comment: "")
            case .connecting:
                return NSLocalizedString("Connecting to relay...", comment: "")
            case .hostListening:
                return NSLocalizedString("Host Listening (Waiting for peer...)", comment: "")
            case .joinerProbing(let count):
                return String(format: NSLocalizedString("Probing for Host (Sent %d probes)...", comment: ""), count)
            case .connected(let sessionId):
                return String(format: NSLocalizedString("Connected (Session: 0x%016llX)", comment: ""), sessionId)
            case .error(let message):
                return String(format: NSLocalizedString("Error: %@", comment: ""), message)
            }
        }
        
        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
        
        public var isConnecting: Bool {
            switch self {
            case .connecting, .hostListening, .joinerProbing:
                return true
            default:
                return false
            }
        }
    }
    
    public struct TrafficStats {
        public var messagesSent: UInt64 = 0
        public var messagesReceived: UInt64 = 0
        public var bytesSent: UInt64 = 0
        public var bytesReceived: UInt64 = 0
        public var retransmissions: UInt64 = 0
        
        public init() {}
    }
    
    @Published public private(set) var state: State = .disconnected
    @Published public private(set) var stats = TrafficStats()
    @Published public var serverURL: String = "wss://mgba-relay.gal-leibo.workers.dev"
    @Published public var roomCode: String = ""
    @Published public var role: Role = .host
    @Published public var roomToken: String = ""
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var probeTimer: Timer?
    private var statsTimer: Timer?
    private var probesSent: Int = 0
    
    public override init() {
        super.init()
        self.roomCode = Self.generateRandomRoomCode()
    }
    
    public static func generateRandomRoomCode() -> String {
        let charset = Array("abcdefghjkmnpqrstuvwxyz23456789")
        let randomSuffix = String((0..<6).compactMap { _ in charset.randomElement() })
        return "trade-\(randomSuffix)"
    }
    
    public func connect() {
        guard self.state == .disconnected || self.isErrorState else { return }
        
        let trimmedRoom = self.roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRoom.isEmpty else {
            self.state = .error(NSLocalizedString("Please enter a room code.", comment: ""))
            return
        }
        
        var urlString = self.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasSuffix("/") {
            urlString.append("/")
        }
        if !urlString.hasSuffix("room/") {
            urlString.append("room/")
        }
        urlString.append(trimmedRoom)
        
        var components = URLComponents(string: urlString)
        let token = self.roomToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            components?.queryItems = [URLQueryItem(name: "token", value: token)]
        }
        
        guard let url = components?.url else {
            self.state = .error(NSLocalizedString("Invalid server URL or room code.", comment: ""))
            return
        }
        
        self.state = .connecting
        self.probesSent = 0
        self.stats = TrafficStats()
        
        let bridge = GBAEmulatorBridge.shared
        let isHost = (self.role == .host)
        
        bridge.wirelessSendDatagramHandler = { [weak self] datagram in
            self?.sendDatagram(datagram)
        }
        
        guard bridge.startWireless(withHost: isHost, sessionId: 0) else {
            self.state = .error(NSLocalizedString("Failed to initialize wireless adapter in core. Start a game first.", comment: ""))
            return
        }
        
        let session = URLSession(configuration: .default)
        self.urlSession = session
        let wsTask = session.webSocketTask(with: url)
        self.webSocketTask = wsTask
        
        wsTask.resume()
        self.listenForMessages()
        
        if isHost {
            self.state = .hostListening
        } else {
            self.state = .joinerProbing(probesSent: 0)
            self.startProbeTimer()
        }
        
        self.startStatsTimer()
    }
    
    public func disconnect() {
        self.probeTimer?.invalidate()
        self.probeTimer = nil
        self.statsTimer?.invalidate()
        self.statsTimer = nil
        
        self.webSocketTask?.cancel(with: .normalClosure, reason: nil)
        self.webSocketTask = nil
        self.urlSession?.invalidateAndCancel()
        self.urlSession = nil
        
        let bridge = GBAEmulatorBridge.shared
        bridge.wirelessSendDatagramHandler = nil
        bridge.stopWireless()
        
        self.state = .disconnected
    }
    
    private var isErrorState: Bool {
        if case .error = self.state { return true }
        return false
    }
    
    private func sendDatagram(_ data: Data) {
        guard let task = self.webSocketTask, task.state == .running else { return }
        let message = URLSessionWebSocketTask.Message.data(data)
        task.send(message) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.handleError(error.localizedDescription)
                }
            } else {
                DispatchQueue.main.async {
                    self?.stats.messagesSent += 1
                    self?.stats.bytesSent += UInt64(data.count)
                }
            }
        }
    }
    
    private func listenForMessages() {
        self.webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleReceivedData(data)
                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        self.handleReceivedData(data)
                    }
                @unknown default:
                    break
                }
                self.listenForMessages()
                
            case .failure(let error):
                DispatchQueue.main.async {
                    self.handleError(error.localizedDescription)
                }
            }
        }
    }
    
    private func handleReceivedData(_ data: Data) {
        guard data.count >= 40 else { return }
        
        // Verify MRFU prefix
        if data.starts(with: [0x4D, 0x52, 0x46, 0x55]) {
            GBAEmulatorBridge.shared.receiveWirelessDatagram(data)
            DispatchQueue.main.async {
                self.stats.messagesReceived += 1
                self.stats.bytesReceived += UInt64(data.count)
            }
        }
    }
    
    private func startProbeTimer() {
        self.probeTimer?.invalidate()
        self.probeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if case .joinerProbing = self.state {
                if let probe = GBAEmulatorBridge.shared.generateWirelessDiscoveryProbe() {
                    self.sendDatagram(probe)
                    self.probesSent += 1
                    self.state = .joinerProbing(probesSent: self.probesSent)
                }
            }
        }
    }
    
    private func startStatsTimer() {
        self.statsTimer?.invalidate()
        self.statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateStatusAndStats()
        }
    }
    
    private func updateStatusAndStats() {
        let bridge = GBAEmulatorBridge.shared
        var sessionId: UInt64 = 0
        var sessionActive: ObjCBool = false
        var adapterConnected: ObjCBool = false
        var retransmissions: UInt64 = 0
        var parseFailures: UInt64 = 0
        var overflowed: UInt64 = 0
        
        bridge.getWirelessStats(withSessionId: &sessionId,
                                sessionActive: &sessionActive,
                                adapterConnected: &adapterConnected,
                                retransmissions: &retransmissions,
                                parseFailures: &parseFailures,
                                overflowed: &overflowed)
        
        self.stats.retransmissions = retransmissions
        
        if sessionActive.boolValue && sessionId != 0 {
            self.probeTimer?.invalidate()
            self.probeTimer = nil
            if self.state != .connected(sessionId: sessionId) {
                self.state = .connected(sessionId: sessionId)
            }
        }
    }
    
    private func handleError(_ error: String) {
        guard self.state != .disconnected else { return }
        self.disconnect()
        self.state = .error(error)
    }
}

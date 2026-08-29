//
//  GBAWirelessManager.swift
//  GBADeltaCore
//
//  Created for mGBA Wireless Adapter (RFU) Online Relay Support.
//

import Foundation

public final class GBAWirelessManager: NSObject, ObservableObject {
    public static let shared = GBAWirelessManager()
    
    public enum State: Equatable {
        case disconnected
        case connecting
        case waitingForPartner(roomCode: String)
        case connected(peerCount: Int, isHost: Bool, sessionId: UInt64)
        case error(String)
        
        public var description: String {
            switch self {
            case .disconnected:
                return NSLocalizedString("Disconnected", comment: "")
            case .connecting:
                return NSLocalizedString("Connecting to relay...", comment: "")
            case .waitingForPartner(let room):
                return String(format: NSLocalizedString("Waiting for partner to join room '%@'...", comment: ""), room)
            case .connected(let count, let isHost, _):
                let roleStr = isHost ? NSLocalizedString("Host", comment: "") : NSLocalizedString("Client", comment: "")
                if count >= 2 {
                    return String(format: NSLocalizedString("Connected! (2/2 in room • %@)", comment: ""), roleStr)
                } else {
                    return String(format: NSLocalizedString("Connected (%@ • %d/2 in room)", comment: ""), roleStr, count)
                }
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
            case .connecting, .waitingForPartner:
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
    @Published public var roomToken: String = ""
    @Published public private(set) var assignedRole: String? = nil
    @Published public private(set) var activeSessionId: UInt64 = 0
    @Published public private(set) var peerCount: Int = 0
    
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
        self.assignedRole = nil
        self.activeSessionId = 0
        self.peerCount = 0
        
        let bridge = GBAEmulatorBridge.shared
        bridge.wirelessSendDatagramHandler = { [weak self] datagram in
            self?.sendDatagram(datagram)
        }
        
        let session = URLSession(configuration: .default)
        self.urlSession = session
        let wsTask = session.webSocketTask(with: url)
        self.webSocketTask = wsTask
        
        wsTask.resume()
        self.listenForMessages()
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
        
        self.assignedRole = nil
        self.activeSessionId = 0
        self.peerCount = 0
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
                    self.handleReceivedText(text)
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
    
    private func handleReceivedText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let trimmedRoom = self.roomCode.trimmingCharacters(in: .whitespacesAndNewlines)
            
            switch type {
            case "assigned_role":
                let role = json["role"] as? String ?? "host"
                let isHost = (role == "host")
                let sessionIdHex = json["sessionId"] as? String ?? ""
                let cleanHex = sessionIdHex.hasPrefix("0x") ? String(sessionIdHex.dropFirst(2)) : sessionIdHex
                let sessionId = UInt64(cleanHex, radix: 16) ?? 0
                let count = json["peerCount"] as? Int ?? 1
                
                self.assignedRole = role
                self.activeSessionId = sessionId
                self.peerCount = count
                
                let bridge = GBAEmulatorBridge.shared
                if !bridge.startWireless(withHost: isHost, sessionId: sessionId) {
                    self.handleError(NSLocalizedString("Failed to initialize wireless adapter in core. Start a game first.", comment: ""))
                    return
                }
                
                if count < 2 {
                    self.state = .waitingForPartner(roomCode: trimmedRoom)
                } else {
                    self.state = .connected(peerCount: count, isHost: isHost, sessionId: sessionId)
                }
                
                if !isHost {
                    self.startProbeTimer()
                }
                
            case "peer_joined":
                let count = json["peerCount"] as? Int ?? 2
                self.peerCount = count
                let isHost = (self.assignedRole == "host")
                self.state = .connected(peerCount: count, isHost: isHost, sessionId: self.activeSessionId)
                
            case "peer_left":
                let count = json["peerCount"] as? Int ?? 1
                self.peerCount = count
                self.state = .waitingForPartner(roomCode: trimmedRoom)
                
            default:
                break
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
            if self.assignedRole == "client" {
                if let probe = GBAEmulatorBridge.shared.generateWirelessDiscoveryProbe() {
                    self.sendDatagram(probe)
                    self.probesSent += 1
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
            let isHost = (self.assignedRole == "host")
            if case .connected(let count, _, _) = self.state {
                if count != self.peerCount {
                    self.state = .connected(peerCount: self.peerCount, isHost: isHost, sessionId: sessionId)
                }
            } else {
                self.state = .connected(peerCount: max(self.peerCount, 2), isHost: isHost, sessionId: sessionId)
            }
        }
    }
    
    private func handleError(_ error: String) {
        guard self.state != .disconnected else { return }
        self.disconnect()
        self.state = .error(error)
    }
}


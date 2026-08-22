import Darwin
import Foundation

final class AppleMediaReceiver: @unchecked Sendable {
    private enum PacketTarget { case control, primaryVideo, secondaryVideo }
    private static let maximumQueuedPackets = 16_384
    private static let maximumDatagramLength = 65_535

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let remoteAddress: in_addr
    private let controlSocket: Int32
    private let videoSocket: Int32
    private let secondaryVideoSocket: Int32?
    private let controlSource: DispatchSourceRead
    private let videoSource: DispatchSourceRead
    private let secondaryVideoSource: DispatchSourceRead?
    private let punchTimer: DispatchSourceTimer
    private var controlPackets = [Data]()
    private var videoPackets = [Data]()
    private var secondaryVideoPackets = [Data]()
    private var isClosed = false

    init(
        endpoint: ConnectionEndpoint,
        mediaHost: String? = nil,
        displayCount: Int = 1
    ) throws {
        let maximumPortOffset: UInt16 = displayCount > 1 ? 2 : 1
        guard endpoint.port <= UInt16.max - maximumPortOffset else {
            throw AppleMediaReceiverError.invalidPort
        }
        let remoteAddress = try Self.resolveIPv4(mediaHost ?? endpoint.host)
        self.remoteAddress = remoteAddress
        controlSocket = try Self.makeSocket(localPort: endpoint.port, remoteAddress: remoteAddress, remotePort: endpoint.port)
        do {
            videoSocket = try Self.makeSocket(
                localPort: endpoint.port + 1,
                remoteAddress: remoteAddress,
                remotePort: endpoint.port + 1
            )
        } catch {
            Darwin.close(controlSocket)
            throw error
        }
        let preparedSecondaryVideoSocket: Int32?
        if displayCount > 1 {
            do {
                preparedSecondaryVideoSocket = try Self.makeSocket(
                    localPort: endpoint.port + 2,
                    remoteAddress: remoteAddress,
                    remotePort: endpoint.port + 2
                )
            } catch {
                Darwin.close(videoSocket)
                Darwin.close(controlSocket)
                throw error
            }
        } else {
            preparedSecondaryVideoSocket = nil
        }
        secondaryVideoSocket = preparedSecondaryVideoSocket

        let receiverQueue = DispatchQueue(label: "com.isharescreen.media-receiver")
        queue = receiverQueue
        controlSource = DispatchSource.makeReadSource(fileDescriptor: controlSocket, queue: receiverQueue)
        videoSource = DispatchSource.makeReadSource(fileDescriptor: videoSocket, queue: receiverQueue)
        if let preparedSecondaryVideoSocket {
            secondaryVideoSource = DispatchSource.makeReadSource(
                fileDescriptor: preparedSecondaryVideoSocket,
                queue: receiverQueue
            )
        } else {
            secondaryVideoSource = nil
        }
        punchTimer = DispatchSource.makeTimerSource(queue: receiverQueue)

        controlSource.setEventHandler { [weak self] in self?.drain(self?.controlSocket, target: .control) }
        videoSource.setEventHandler { [weak self] in self?.drain(self?.videoSocket, target: .primaryVideo) }
        secondaryVideoSource?.setEventHandler {
            [weak self] in self?.drain(self?.secondaryVideoSocket, target: .secondaryVideo)
        }
        controlSource.setCancelHandler { [controlSocket] in Darwin.close(controlSocket) }
        videoSource.setCancelHandler { [videoSocket] in Darwin.close(videoSocket) }
        secondaryVideoSource?.setCancelHandler { [secondaryVideoSocket] in
            if let secondaryVideoSocket { Darwin.close(secondaryVideoSocket) }
        }
        punchTimer.setEventHandler { [weak self] in self?.punch() }
        punchTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
        controlSource.activate()
        videoSource.activate()
        secondaryVideoSource?.activate()
        punchTimer.activate()
    }

    var queuedVideoPacketCount: Int {
        lock.withLock { videoPackets.count }
    }

    func drainVideoPackets(mediaStreamIndex: Int = 0) -> [Data] {
        lock.withLock {
            if mediaStreamIndex == 1 {
                defer { secondaryVideoPackets.removeAll(keepingCapacity: true) }
                return secondaryVideoPackets
            }
            defer { videoPackets.removeAll(keepingCapacity: true) }
            return videoPackets
        }
    }

    func drainControlPackets() -> [Data] {
        lock.withLock {
            defer { controlPackets.removeAll(keepingCapacity: true) }
            return controlPackets
        }
    }

    func sendControl(_ datagram: Data) throws {
        try send(datagram, through: controlSocket)
    }

    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws {
        if mediaStreamIndex == 1 {
            guard let secondaryVideoSocket else {
                throw AppleMediaReceiverError.secondaryVideoUnavailable
            }
            try send(datagram, through: secondaryVideoSocket)
        } else {
            try send(datagram, through: videoSocket)
        }
    }

    func configureRemotePorts(_ ports: AppleMediaPorts) throws {
        let expectedVideoCount = secondaryVideoSocket == nil ? 1 : 2
        guard ports.videos.count == expectedVideoCount else {
            throw AppleMediaReceiverError.invalidPort
        }
        let isOpen = lock.withLock { !isClosed }
        guard isOpen else { throw AppleMediaReceiverError.closed }
        try Self.connect(controlSocket, remoteAddress: remoteAddress, remotePort: ports.audio)
        try Self.connect(videoSocket, remoteAddress: remoteAddress, remotePort: ports.videos[0])
        if let secondaryVideoSocket {
            try Self.connect(
                secondaryVideoSocket,
                remoteAddress: remoteAddress,
                remotePort: ports.videos[1]
            )
        }
    }

    private func send(_ datagram: Data, through socket: Int32) throws {
        let isOpen = lock.withLock { !isClosed }
        guard isOpen else { throw AppleMediaReceiverError.closed }
        let sent = datagram.withUnsafeBytes { bytes in
            Darwin.send(socket, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == datagram.count else { throw AppleMediaReceiverError.sendFailed(errno) }
    }

    func stopPunching() {
        punchTimer.cancel()
    }

    func close() {
        let shouldClose = lock.withLock {
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        guard shouldClose else { return }
        punchTimer.cancel()
        controlSource.cancel()
        videoSource.cancel()
        secondaryVideoSource?.cancel()
    }

    deinit {
        close()
    }

    private func punch() {
        var byte: UInt8 = 0
        _ = Darwin.send(controlSocket, &byte, 1, 0)
        _ = Darwin.send(videoSocket, &byte, 1, 0)
        if let secondaryVideoSocket {
            _ = Darwin.send(secondaryVideoSocket, &byte, 1, 0)
        }
    }

    private func drain(_ socket: Int32?, target: PacketTarget) {
        guard let socket else { return }
        var buffer = [UInt8](repeating: 0, count: Self.maximumDatagramLength)
        while true {
            let count = Darwin.recv(socket, &buffer, buffer.count, MSG_DONTWAIT)
            guard count > 0 else { break }
            let packet = Data(buffer.prefix(count))
            lock.withLock {
                switch target {
                case .control: Self.enqueue(packet, in: &controlPackets)
                case .primaryVideo: Self.enqueue(packet, in: &videoPackets)
                case .secondaryVideo: Self.enqueue(packet, in: &secondaryVideoPackets)
                }
            }
        }
    }

    private static func enqueue(_ packet: Data, in packets: inout [Data]) {
        if packets.count == maximumQueuedPackets {
            packets.removeFirst(maximumQueuedPackets / 4)
        }
        packets.append(packet)
    }

    private static func makeSocket(
        localPort: UInt16,
        remoteAddress: in_addr,
        remotePort: UInt16
    ) throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw AppleMediaReceiverError.socketCreationFailed(errno) }
        do {
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw AppleMediaReceiverError.socketConfigurationFailed(errno)
            }
            var receiveBuffer = Int32(4 * 1_024 * 1_024)
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBuffer,
                socklen_t(MemoryLayout.size(ofValue: receiveBuffer))
            )
            var local = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: localPort.bigEndian,
                sin_addr: in_addr(s_addr: INADDR_ANY),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            let bindResult = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else { throw AppleMediaReceiverError.bindFailed(localPort, errno) }

            try connect(descriptor, remoteAddress: remoteAddress, remotePort: remotePort)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func connect(
        _ descriptor: Int32,
        remoteAddress: in_addr,
        remotePort: UInt16
    ) throws {
        var remote = sockaddr_in(
            sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
            sin_family: sa_family_t(AF_INET),
            sin_port: remotePort.bigEndian,
            sin_addr: remoteAddress,
            sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
        )
        let result = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw AppleMediaReceiverError.connectionFailed(errno) }
    }

    private static func resolveIPv4(_ host: String) throws -> in_addr {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_INET,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let result else {
            throw AppleMediaReceiverError.ipv4ResolutionFailed
        }
        defer { freeaddrinfo(result) }
        return result.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            $0.pointee.sin_addr
        }
    }
}

enum AppleMediaReceiverError: LocalizedError {
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case bindFailed(UInt16, Int32)
    case connectionFailed(Int32)
    case ipv4ResolutionFailed
    case invalidPort
    case secondaryVideoUnavailable
    case closed
    case sendFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed, .socketConfigurationFailed, .connectionFailed:
            "The UDP media connection could not be prepared."
        case .bindFailed(let port, _):
            "UDP port \(port) is unavailable for Screen Sharing media."
        case .ipv4ResolutionFailed:
            "The remote Mac does not have a usable IPv4 address for media streaming."
        case .invalidPort:
            "The Screen Sharing port is too high to allocate its media port."
        case .secondaryVideoUnavailable:
            "The secondary Screen Sharing video connection is unavailable."
        case .closed:
            "The Screen Sharing media connection is closed."
        case .sendFailed:
            "Screen Sharing recovery feedback could not be sent."
        }
    }
}

protocol AppleMediaControlSending: Sendable {
    func sendControl(_ datagram: Data) throws
}

extension AppleMediaReceiver: AppleMediaControlSending {}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

import Darwin
import Foundation

struct AppleReceivedVideoDatagram: Equatable, Sendable {
    let data: Data
    let arrivalTime: TimeInterval
}

typealias AppleVideoDatagramHandler = @Sendable (AppleReceivedVideoDatagram) -> Void

final class AppleMediaReceiver: @unchecked Sendable {
    private static let maximumQueuedControlPackets = 16_384
    private static let maximumDatagramLength = 65_535

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let remoteAddress: ResolvedRemoteAddress
    private let controlSocket: Int32
    private let videoSocket: Int32
    private let secondaryVideoSocket: Int32?
    private let controlSource: DispatchSourceRead
    private var videoSource: DispatchSourceRead?
    private var secondaryVideoSource: DispatchSourceRead?
    private let punchTimer: DispatchSourceTimer
    private var controlPackets = [Data]()
    private var isClosed = false

    init(
        remoteAddress: ResolvedRemoteAddress,
        displayCount: Int = 1
    ) throws {
        let maximumPortOffset: UInt16 = displayCount > 1 ? 2 : 1
        guard remoteAddress.port <= UInt16.max - maximumPortOffset else {
            throw AppleMediaReceiverError.invalidPort
        }
        self.remoteAddress = remoteAddress
        controlSocket = try Self.makeSocket(
            localPort: remoteAddress.port,
            remoteAddress: remoteAddress,
            remotePort: remoteAddress.port
        )
        do {
            videoSocket = try Self.makeSocket(
                localPort: remoteAddress.port + 1,
                remoteAddress: remoteAddress,
                remotePort: remoteAddress.port + 1
            )
        } catch {
            Darwin.close(controlSocket)
            throw error
        }
        let preparedSecondaryVideoSocket: Int32?
        if displayCount > 1 {
            do {
                preparedSecondaryVideoSocket = try Self.makeSocket(
                    localPort: remoteAddress.port + 2,
                    remoteAddress: remoteAddress,
                    remotePort: remoteAddress.port + 2
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
        videoSource = nil
        secondaryVideoSource = nil
        punchTimer = DispatchSource.makeTimerSource(queue: receiverQueue)

        controlSource.setEventHandler { [weak self] in self?.receiveAvailableControlPackets() }
        controlSource.setCancelHandler { [controlSocket] in Darwin.close(controlSocket) }
        punchTimer.setEventHandler { [weak self] in self?.punch() }
        punchTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
        controlSource.activate()
        punchTimer.activate()
    }

    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping @Sendable (AppleReceivedVideoDatagram) -> Void
    ) throws {
        try lock.withLock {
            guard !isClosed else { throw AppleMediaReceiverError.closed }
            switch mediaStreamIndex {
            case 0:
                guard videoSource == nil else {
                    throw AppleMediaReceiverError.videoDeliveryAlreadyStarted
                }
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: videoSocket,
                    queue: deliveryQueue
                )
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.receiveAvailableVideoPackets(
                        socket: self.videoSocket,
                        handler: handler
                    )
                }
                source.setCancelHandler { [videoSocket] in Darwin.close(videoSocket) }
                videoSource = source
            case 1:
                guard secondaryVideoSource == nil, let secondaryVideoSocket else {
                    throw AppleMediaReceiverError.secondaryVideoUnavailable
                }
                let source = DispatchSource.makeReadSource(
                    fileDescriptor: secondaryVideoSocket,
                    queue: deliveryQueue
                )
                source.setEventHandler { [weak self] in
                    self?.receiveAvailableVideoPackets(
                        socket: secondaryVideoSocket,
                        handler: handler
                    )
                }
                source.setCancelHandler { Darwin.close(secondaryVideoSocket) }
                secondaryVideoSource = source
            default:
                throw AppleMediaReceiverError.invalidMediaStreamIndex
            }
            if mediaStreamIndex == 0 {
                videoSource?.activate()
            } else {
                secondaryVideoSource?.activate()
            }
        }
    }

    func stopVideoDelivery(mediaStreamIndex: Int) {
        let source = lock.withLock {
            mediaStreamIndex == 0 ? videoSource : secondaryVideoSource
        }
        source?.cancel()
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
        let resources = lock.withLock { () -> (
            primarySource: DispatchSourceRead?,
            secondarySource: DispatchSourceRead?
        )? in
            guard !isClosed else { return nil }
            isClosed = true
            return (videoSource, secondaryVideoSource)
        }
        guard let resources else { return }
        punchTimer.cancel()
        controlSource.cancel()
        if let primarySource = resources.primarySource {
            primarySource.cancel()
        } else {
            Darwin.close(videoSocket)
        }
        if let secondaryVideoSocket {
            if let secondarySource = resources.secondarySource {
                secondarySource.cancel()
            } else {
                Darwin.close(secondaryVideoSocket)
            }
        }
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

    private func receiveAvailableControlPackets() {
        var buffer = [UInt8](repeating: 0, count: Self.maximumDatagramLength)
        while true {
            let count = Darwin.recv(controlSocket, &buffer, buffer.count, MSG_DONTWAIT)
            guard count > 0 else { break }
            lock.withLock {
                if controlPackets.count == Self.maximumQueuedControlPackets {
                    controlPackets.removeFirst(Self.maximumQueuedControlPackets / 4)
                }
                controlPackets.append(Data(buffer.prefix(count)))
            }
        }
    }

    private func receiveAvailableVideoPackets(
        socket: Int32,
        handler: AppleVideoDatagramHandler
    ) {
        var buffer = [UInt8](repeating: 0, count: Self.maximumDatagramLength)
        while true {
            let arrivalTime = ProcessInfo.processInfo.systemUptime
            let count = Darwin.recv(socket, &buffer, buffer.count, MSG_DONTWAIT)
            guard count > 0 else { return }
            let datagram = AppleReceivedVideoDatagram(
                data: Data(buffer.prefix(count)),
                arrivalTime: arrivalTime
            )
            handler(datagram)
        }
    }

    private static func makeSocket(
        localPort: UInt16,
        remoteAddress: ResolvedRemoteAddress,
        remotePort: UInt16
    ) throws -> Int32 {
        let descriptor = Darwin.socket(Int32(remoteAddress.family), SOCK_DGRAM, IPPROTO_UDP)
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
            try bind(descriptor, family: remoteAddress.family, localPort: localPort)

            try connect(descriptor, remoteAddress: remoteAddress, remotePort: remotePort)
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func connect(
        _ descriptor: Int32,
        remoteAddress: ResolvedRemoteAddress,
        remotePort: UInt16
    ) throws {
        let result = remoteAddress.withSockAddr(port: remotePort) { pointer, length in
            Darwin.connect(descriptor, pointer, length)
        }
        guard result == 0 else { throw AppleMediaReceiverError.connectionFailed(errno) }
    }

    private static func bind(
        _ descriptor: Int32,
        family: sa_family_t,
        localPort: UInt16
    ) throws {
        let result: Int32
        switch Int32(family) {
        case AF_INET:
            var local = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: localPort.bigEndian,
                sin_addr: in_addr(s_addr: INADDR_ANY),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            result = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case AF_INET6:
            var enabled: Int32 = 1
            guard setsockopt(
                descriptor,
                IPPROTO_IPV6,
                IPV6_V6ONLY,
                &enabled,
                socklen_t(MemoryLayout.size(ofValue: enabled))
            ) == 0 else {
                throw AppleMediaReceiverError.socketConfigurationFailed(errno)
            }
            var local = sockaddr_in6(
                sin6_len: UInt8(MemoryLayout<sockaddr_in6>.size),
                sin6_family: sa_family_t(AF_INET6),
                sin6_port: localPort.bigEndian,
                sin6_flowinfo: 0,
                sin6_addr: in6addr_any,
                sin6_scope_id: 0
            )
            result = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        default:
            throw AppleMediaReceiverError.unsupportedAddressFamily
        }
        guard result == 0 else {
            throw AppleMediaReceiverError.bindFailed(localPort, errno)
        }
    }
}

enum AppleMediaReceiverError: LocalizedError {
    case socketCreationFailed(Int32)
    case socketConfigurationFailed(Int32)
    case bindFailed(UInt16, Int32)
    case connectionFailed(Int32)
    case unsupportedAddressFamily
    case invalidPort
    case secondaryVideoUnavailable
    case invalidMediaStreamIndex
    case videoDeliveryAlreadyStarted
    case closed
    case sendFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .socketCreationFailed, .socketConfigurationFailed, .connectionFailed:
            "The UDP media connection could not be prepared."
        case .bindFailed(let port, _):
            "UDP port \(port) is unavailable for Screen Sharing media."
        case .unsupportedAddressFamily:
            "The remote Mac uses an unsupported media address family."
        case .invalidPort:
            "The Screen Sharing port is too high to allocate its media port."
        case .secondaryVideoUnavailable:
            "The secondary Screen Sharing video connection is unavailable."
        case .invalidMediaStreamIndex:
            "The negotiated Screen Sharing video stream index is invalid."
        case .videoDeliveryAlreadyStarted:
            "Screen Sharing video delivery has already started."
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

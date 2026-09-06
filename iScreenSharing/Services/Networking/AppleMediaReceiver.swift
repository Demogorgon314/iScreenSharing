import Darwin
import Foundation
import QuartzCore
import struct ScreenSharingProtocol.AppleMediaPorts

enum AppleVideoNetworkPath: String, Equatable, Sendable {
    case direct = "Direct"
    case tailscaleDirect = "Tailscale direct"
    case tailscalePeerRelay = "Tailscale peer relay"
    case tailscaleDERP = "Tailscale DERP"
    case tailscaleUnknown = "Tailscale unknown"
}

struct AppleReceivedVideoDatagram: Equatable, Sendable {
    let data: Data
    let arrivalTime: TimeInterval
    let receiveBatchStartedAt: TimeInterval
    let estimatedSocketBacklogBytes: Int
    let ingressAge: TimeInterval?
    let kernelArrivalTime: TimeInterval?
    let receiveBufferOverflowCount: UInt64?
    let networkPath: AppleVideoNetworkPath

    init(
        data: Data,
        arrivalTime: TimeInterval,
        receiveBatchStartedAt: TimeInterval? = nil,
        estimatedSocketBacklogBytes: Int = 0,
        ingressAge: TimeInterval? = nil,
        kernelArrivalTime: TimeInterval? = nil,
        receiveBufferOverflowCount: UInt64? = nil,
        networkPath: AppleVideoNetworkPath = .direct
    ) {
        self.data = data
        self.arrivalTime = arrivalTime
        self.receiveBatchStartedAt = receiveBatchStartedAt ?? arrivalTime
        self.estimatedSocketBacklogBytes = max(0, estimatedSocketBacklogBytes)
        self.ingressAge = ingressAge.map { max(0, $0) }
        self.kernelArrivalTime = kernelArrivalTime
        self.receiveBufferOverflowCount = receiveBufferOverflowCount
        self.networkPath = networkPath
    }
}

typealias AppleVideoDatagramHandler = @Sendable (AppleReceivedVideoDatagram) -> Void

struct AppleMediaReceiveBufferConfiguration: Equatable, Sendable {
    let requestedBytes: Int?
    let actualBytes: Int?
}

protocol AppleMediaReceiving: AppleMediaControlSending, AnyObject, Sendable {
    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws
    func stopVideoDelivery(mediaStreamIndex: Int)
    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration?
    func drainControlPackets() -> [Data]
    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws
    func configureRemotePorts(_ ports: AppleMediaPorts) throws
    func stopPunching()
    func close()
}

final class AppleMediaReceiver: AppleMediaReceiving, @unchecked Sendable {
    private static let maximumQueuedControlPackets = 16_384
    private static let maximumDatagramLength = 65_535
    private static let controlReceiveBufferBytes = 4 * 1_024 * 1_024
    static let requestedVideoReceiveBufferBytes: Int? = requestedVideoReceiveBufferBytes(
        environment: ProcessInfo.processInfo.environment
    )

    private struct PreparedSocket {
        let descriptor: Int32
        let receiveBuffer: AppleMediaReceiveBufferConfiguration
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private let remoteAddress: ResolvedRemoteAddress
    private let controlSocket: Int32
    private let videoSocket: Int32
    private let secondaryVideoSocket: Int32?
    private let videoReceiveBuffer: AppleMediaReceiveBufferConfiguration
    private let secondaryVideoReceiveBuffer: AppleMediaReceiveBufferConfiguration?
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
        let preparedControlSocket = try Self.makeSocket(
            localPort: remoteAddress.port,
            remoteAddress: remoteAddress,
            remotePort: remoteAddress.port,
            requestedReceiveBufferBytes: Self.controlReceiveBufferBytes
        )
        controlSocket = preparedControlSocket.descriptor
        let preparedVideoSocket: PreparedSocket
        do {
            preparedVideoSocket = try Self.makeSocket(
                localPort: remoteAddress.port + 1,
                remoteAddress: remoteAddress,
                remotePort: remoteAddress.port + 1,
                requestedReceiveBufferBytes: Self.requestedVideoReceiveBufferBytes,
                recordsMonotonicTimestamps: Self.recordsVideoMonotonicTimestamps
            )
        } catch {
            Darwin.close(controlSocket)
            throw error
        }
        videoSocket = preparedVideoSocket.descriptor
        videoReceiveBuffer = preparedVideoSocket.receiveBuffer
        let preparedSecondaryVideoSocket: PreparedSocket?
        if displayCount > 1 {
            do {
                preparedSecondaryVideoSocket = try Self.makeSocket(
                    localPort: remoteAddress.port + 2,
                    remoteAddress: remoteAddress,
                    remotePort: remoteAddress.port + 2,
                    requestedReceiveBufferBytes: Self.requestedVideoReceiveBufferBytes,
                    recordsMonotonicTimestamps: Self.recordsVideoMonotonicTimestamps
                )
            } catch {
                Darwin.close(videoSocket)
                Darwin.close(controlSocket)
                throw error
            }
        } else {
            preparedSecondaryVideoSocket = nil
        }
        secondaryVideoSocket = preparedSecondaryVideoSocket?.descriptor
        secondaryVideoReceiveBuffer = preparedSecondaryVideoSocket?.receiveBuffer

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
                        estimatedSocketBacklogBytes: Int(self.videoSource?.data ?? 0),
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
                    guard let self else { return }
                    self.receiveAvailableVideoPackets(
                        socket: secondaryVideoSocket,
                        estimatedSocketBacklogBytes: Int(self.secondaryVideoSource?.data ?? 0),
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

    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? {
        switch mediaStreamIndex {
        case 0:
            videoReceiveBuffer
        case 1:
            secondaryVideoReceiveBuffer
        default:
            nil
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
        estimatedSocketBacklogBytes: Int,
        handler: AppleVideoDatagramHandler
    ) {
        let receiveBatchStartedAt = CACurrentMediaTime()
        var buffer = [UInt8](repeating: 0, count: Self.maximumDatagramLength)
#if os(iOS)
        var controlBuffer = [UInt8](repeating: 0, count: 64)
#endif
        while true {
#if os(iOS)
            let received = Self.receiveTimestampedDatagram(
                socket: socket,
                buffer: &buffer,
                controlBuffer: &controlBuffer
            )
            let count = received.count
            let readAt = CACurrentMediaTime()
            let kernelArrivalTime = received.monotonicTimestamp
            let arrivalTime = readAt
#else
            let arrivalTime = CACurrentMediaTime()
            let count = Darwin.recv(socket, &buffer, buffer.count, MSG_DONTWAIT)
#endif
            guard count > 0 else { return }
#if os(iOS)
            let ingressAge = kernelArrivalTime.map { max(0, readAt - $0) }
#else
            let ingressAge: TimeInterval? = nil
            let kernelArrivalTime: TimeInterval? = nil
#endif
            let datagram = AppleReceivedVideoDatagram(
                data: Data(buffer.prefix(count)),
                arrivalTime: arrivalTime,
                receiveBatchStartedAt: receiveBatchStartedAt,
                estimatedSocketBacklogBytes: estimatedSocketBacklogBytes,
                ingressAge: ingressAge,
                kernelArrivalTime: kernelArrivalTime
            )
            handler(datagram)
        }
    }

#if os(iOS)
    private static func receiveTimestampedDatagram(
        socket: Int32,
        buffer: inout [UInt8],
        controlBuffer: inout [UInt8]
    ) -> (count: Int, monotonicTimestamp: TimeInterval?) {
        var vector = iovec()
        var message = msghdr()
        let count = buffer.withUnsafeMutableBytes { bufferBytes in
            controlBuffer.withUnsafeMutableBytes { controlBytes in
                vector.iov_base = bufferBytes.baseAddress
                vector.iov_len = bufferBytes.count
                return withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBytes.baseAddress
                    message.msg_controllen = socklen_t(controlBytes.count)
                    return Darwin.recvmsg(socket, &message, MSG_DONTWAIT)
                }
            }
        }
        guard count > 0 else { return (count, nil) }
        let timestamp = controlBuffer.withUnsafeBytes { bytes -> UInt64? in
            let headerSize = MemoryLayout<cmsghdr>.size
            let alignedHeaderSize = (headerSize + 3) & ~3
            var offset = 0
            let controlLength = min(Int(message.msg_controllen), bytes.count)
            while offset + headerSize <= controlLength {
                let header = bytes.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
                let messageLength = Int(header.cmsg_len)
                guard messageLength >= alignedHeaderSize,
                      offset + messageLength <= controlLength else { return nil }
                if header.cmsg_level == SOL_SOCKET,
                   header.cmsg_type == SCM_TIMESTAMP_MONOTONIC,
                   offset + alignedHeaderSize + MemoryLayout<UInt64>.size <= controlLength {
                    return bytes.loadUnaligned(
                        fromByteOffset: offset + alignedHeaderSize,
                        as: UInt64.self
                    )
                }
                offset += (messageLength + 3) & ~3
            }
            return nil
        }
        return (count, timestamp.map(monotonicSeconds))
    }

    private static func monotonicSeconds(_ absoluteTime: UInt64) -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(absoluteTime)
            * Double(timebase.numer)
            / Double(timebase.denom)
            / 1_000_000_000
    }
#endif

    private static func makeSocket(
        localPort: UInt16,
        remoteAddress: ResolvedRemoteAddress,
        remotePort: UInt16,
        requestedReceiveBufferBytes: Int?,
        recordsMonotonicTimestamps: Bool = false
    ) throws -> PreparedSocket {
        let descriptor = Darwin.socket(Int32(remoteAddress.family), SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw AppleMediaReceiverError.socketCreationFailed(errno) }
        do {
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
                throw AppleMediaReceiverError.socketConfigurationFailed(errno)
            }
            if recordsMonotonicTimestamps {
                var timestampsEnabled: Int32 = 1
                _ = setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_TIMESTAMP_MONOTONIC,
                    &timestampsEnabled,
                    socklen_t(MemoryLayout.size(ofValue: timestampsEnabled))
                )
            }
            if let requestedReceiveBufferBytes {
                var receiveBuffer = Int32(clamping: requestedReceiveBufferBytes)
                _ = setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_RCVBUF,
                    &receiveBuffer,
                    socklen_t(MemoryLayout.size(ofValue: receiveBuffer))
                )
            }
            try bind(descriptor, family: remoteAddress.family, localPort: localPort)

            try connect(descriptor, remoteAddress: remoteAddress, remotePort: remotePort)
            return PreparedSocket(
                descriptor: descriptor,
                receiveBuffer: AppleMediaReceiveBufferConfiguration(
                    requestedBytes: requestedReceiveBufferBytes,
                    actualBytes: receiveBufferSize(of: descriptor)
                )
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    static func receiveBufferSize(of descriptor: Int32) -> Int? {
        var receiveBuffer: Int32 = 0
        var length = socklen_t(MemoryLayout.size(ofValue: receiveBuffer))
        let result = getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVBUF,
            &receiveBuffer,
            &length
        )
        guard result == 0, length == MemoryLayout.size(ofValue: receiveBuffer) else {
            return nil
        }
        return max(0, Int(receiveBuffer))
    }

    static func requestedVideoReceiveBufferBytes(
        environment: [String: String]
    ) -> Int? {
#if DEBUG
        guard let rawValue = environment["ISHARESCREEN_VIDEO_RCVBUF_BYTES"],
              let byteCount = Int(rawValue),
              byteCount > 0,
              byteCount <= Int(Int32.max) else { return nil }
        return byteCount
#else
        nil
#endif
    }

    private static var recordsVideoMonotonicTimestamps: Bool {
#if os(iOS)
        true
#else
        false
#endif
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

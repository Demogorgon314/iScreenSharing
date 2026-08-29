import Darwin
import Foundation
import QuartzCore
import struct ScreenSharingProtocol.AppleMediaPorts
import TailscaleKit

final class TailscaleMediaReceiver: AppleMediaReceiving, @unchecked Sendable {
    private static let maximumQueuedControlPackets = 16_384
    private static let maximumDatagramLength = 65_535
    private static let maximumRemoteAddressLength = 128
    private static let networkPathRefreshInterval: TimeInterval = 5

    private struct PacketReadBuffer {
        var data = [UInt8](repeating: 0, count: maximumDatagramLength)
        var remoteAddress = [CChar](repeating: 0, count: maximumRemoteAddressLength)
    }

    private struct ReceivedPacket {
        let data: Data
        let remoteAddress: String
        let readCompletedAt: TimeInterval
        let ingressAge: TimeInterval
        let receiveBufferOverflowCount: UInt64
    }

    private let tailscaleHandle: TailscaleHandle
    private let nodeProvider: any TailscaleNodeProviding
    private let remoteHost: String
    private let displayCount: Int
    private let lock = NSLock()
    private let controlReceiveQueue = DispatchQueue(label: "com.isharescreen.tailscale-media-control")
    private let videoReceiveQueues: [DispatchQueue]
    private let punchQueue = DispatchQueue(label: "com.isharescreen.tailscale-media-punch")
    private let punchTimer: DispatchSourceTimer
    private var controlPacket: TailscalePacketConnection
    private var videoPackets: [TailscalePacketConnection]
    private var controlTarget: String
    private var videoTargets: [String]
    private var videoDeliveryStarted: [Bool]
    private var controlPackets = [Data]()
    private var isPunching = true
    private var isClosed = false
    private var networkPath = AppleVideoNetworkPath.tailscaleUnknown
    private var lastNetworkPathRefreshAt: TimeInterval = 0
    private var isNetworkPathRefreshInFlight = false

    static func create(
        remoteAddress: ResolvedRemoteAddress,
        displayCount: Int,
        nodeProvider: any TailscaleNodeProviding = EmbeddedTailscaleRuntime.shared
    ) async throws -> TailscaleMediaReceiver {
        let maximumPortOffset: UInt16 = displayCount > 1 ? 2 : 1
        guard remoteAddress.port <= UInt16.max - maximumPortOffset,
              (1...2).contains(displayCount) else {
            throw AppleMediaReceiverError.invalidPort
        }
        try await nodeProvider.start()
        let handle = try await nodeProvider.tailscaleHandle()
        let addresses = try await nodeProvider.tailscaleLocalAddresses()
        guard let localHost = localHost(
            matching: remoteAddress.family,
            from: addresses
        ) else {
            throw TailscaleMediaReceiverError.missingLocalAddress
        }
        return try TailscaleMediaReceiver(
            tailscaleHandle: handle,
            nodeProvider: nodeProvider,
            localHost: localHost,
            remoteHost: remoteAddress.numericHost,
            basePort: remoteAddress.port,
            displayCount: displayCount
        )
    }

    private init(
        tailscaleHandle: TailscaleHandle,
        nodeProvider: any TailscaleNodeProviding,
        localHost: String,
        remoteHost: String,
        basePort: UInt16,
        displayCount: Int
    ) throws {
        self.tailscaleHandle = tailscaleHandle
        self.nodeProvider = nodeProvider
        self.remoteHost = remoteHost
        self.displayCount = displayCount
        var openedPackets = [TailscalePacketConnection]()
        do {
            controlPacket = try Self.openPacket(
                tailscaleHandle: tailscaleHandle,
                localAddress: Self.address(host: localHost, port: basePort)
            )
            openedPackets.append(controlPacket)
            var videos = [TailscalePacketConnection]()
            for index in 0..<displayCount {
                let packet = try Self.openPacket(
                    tailscaleHandle: tailscaleHandle,
                    localAddress: Self.address(
                        host: localHost,
                        port: basePort + UInt16(index + 1)
                    )
                )
                videos.append(packet)
                openedPackets.append(packet)
            }
            videoPackets = videos
        } catch {
            openedPackets.forEach { tailscale_packet_close($0) }
            throw error
        }

        controlTarget = Self.address(host: remoteHost, port: basePort)
        videoTargets = (0..<displayCount).map {
            Self.address(host: remoteHost, port: basePort + UInt16($0 + 1))
        }
        videoDeliveryStarted = Array(repeating: false, count: displayCount)
        videoReceiveQueues = (0..<displayCount).map {
            DispatchQueue(label: "com.isharescreen.tailscale-media-video-\($0)")
        }
        punchTimer = DispatchSource.makeTimerSource(queue: punchQueue)
        punchTimer.setEventHandler { [weak self] in self?.punch() }
        punchTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
        punchTimer.activate()
        controlReceiveQueue.async { [weak self, controlPacket] in
            self?.receiveControlPackets(packet: controlPacket)
        }
    }

    func startVideoDelivery(
        mediaStreamIndex: Int,
        on deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) throws {
        let packet = try lock.withTailscaleMediaLock { () -> TailscalePacketConnection in
            guard !isClosed else { throw AppleMediaReceiverError.closed }
            guard videoPackets.indices.contains(mediaStreamIndex) else {
                throw AppleMediaReceiverError.invalidMediaStreamIndex
            }
            guard !videoDeliveryStarted[mediaStreamIndex] else {
                throw AppleMediaReceiverError.videoDeliveryAlreadyStarted
            }
            let packet = videoPackets[mediaStreamIndex]
            guard packet != 0 else { throw AppleMediaReceiverError.closed }
            videoDeliveryStarted[mediaStreamIndex] = true
            return packet
        }
        videoReceiveQueues[mediaStreamIndex].async { [weak self] in
            self?.receiveVideoPackets(
                packet: packet,
                mediaStreamIndex: mediaStreamIndex,
                deliveryQueue: deliveryQueue,
                handler: handler
            )
        }
    }

    func stopVideoDelivery(mediaStreamIndex: Int) {
        let packet = lock.withTailscaleMediaLock { () -> TailscalePacketConnection in
            guard videoPackets.indices.contains(mediaStreamIndex) else { return 0 }
            let packet = videoPackets[mediaStreamIndex]
            videoPackets[mediaStreamIndex] = 0
            return packet
        }
        if packet != 0 { tailscale_packet_close(packet) }
    }

    func videoReceiveBufferConfiguration(
        mediaStreamIndex: Int
    ) -> AppleMediaReceiveBufferConfiguration? {
        guard (0..<displayCount).contains(mediaStreamIndex) else { return nil }
        return AppleMediaReceiveBufferConfiguration(requestedBytes: nil, actualBytes: nil)
    }

    func drainControlPackets() -> [Data] {
        lock.withTailscaleMediaLock {
            defer { controlPackets.removeAll(keepingCapacity: true) }
            return controlPackets
        }
    }

    func sendControl(_ datagram: Data) throws {
        let destination = try lock.withTailscaleMediaLock {
            guard !isClosed, controlPacket != 0 else { throw AppleMediaReceiverError.closed }
            return (controlPacket, controlTarget)
        }
        try send(datagram, packet: destination.0, target: destination.1)
    }

    func sendVideoControl(_ datagram: Data, mediaStreamIndex: Int) throws {
        let destination = try lock.withTailscaleMediaLock {
            guard !isClosed else { throw AppleMediaReceiverError.closed }
            guard videoPackets.indices.contains(mediaStreamIndex) else {
                throw AppleMediaReceiverError.invalidMediaStreamIndex
            }
            let packet = videoPackets[mediaStreamIndex]
            guard packet != 0 else { throw AppleMediaReceiverError.closed }
            return (packet, videoTargets[mediaStreamIndex])
        }
        try send(datagram, packet: destination.0, target: destination.1)
    }

    func configureRemotePorts(_ ports: AppleMediaPorts) throws {
        try lock.withTailscaleMediaLock {
            guard !isClosed else { throw AppleMediaReceiverError.closed }
            guard ports.videos.count == videoTargets.count else {
                throw AppleMediaReceiverError.invalidPort
            }
            controlTarget = Self.address(host: remoteHost, port: ports.audio)
            videoTargets = ports.videos.map { Self.address(host: remoteHost, port: $0) }
        }
    }

    func stopPunching() {
        let shouldCancel = lock.withTailscaleMediaLock { () -> Bool in
            guard isPunching else { return false }
            isPunching = false
            return true
        }
        if shouldCancel { punchTimer.cancel() }
    }

    func close() {
        let packets = lock.withTailscaleMediaLock { () -> [TailscalePacketConnection]? in
            guard !isClosed else { return nil }
            isClosed = true
            let packets = [controlPacket] + videoPackets
            controlPacket = 0
            videoPackets = Array(repeating: 0, count: videoPackets.count)
            return packets
        }
        guard let packets else { return }
        stopPunching()
        packets.filter { $0 != 0 }.forEach { tailscale_packet_close($0) }
    }

    deinit {
        close()
    }

    static func address(host: String, port: UInt16) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    static func localHost(matching family: sa_family_t, from addresses: [String]) -> String? {
        switch Int32(family) {
        case AF_INET:
            addresses.first { !$0.contains(":") }
        case AF_INET6:
            addresses.first { $0.contains(":") }
        default:
            nil
        }
    }

    private func punch() {
        try? sendControl(Data([0]))
        let count = lock.withTailscaleMediaLock { videoTargets.count }
        for index in 0..<count {
            try? sendVideoControl(Data([0]), mediaStreamIndex: index)
        }
    }

    private func receiveControlPackets(packet: TailscalePacketConnection) {
        var readBuffer = PacketReadBuffer()
        while true {
            guard let received = Self.receive(packet: packet, using: &readBuffer) else { return }
            let expectedTarget = lock.withTailscaleMediaLock { controlTarget }
            guard received.remoteAddress == expectedTarget else { continue }
            lock.withTailscaleMediaLock {
                guard !isClosed else { return }
                if controlPackets.count == Self.maximumQueuedControlPackets {
                    controlPackets.removeFirst(Self.maximumQueuedControlPackets / 4)
                }
                controlPackets.append(received.data)
            }
        }
    }

    private func receiveVideoPackets(
        packet: TailscalePacketConnection,
        mediaStreamIndex: Int,
        deliveryQueue: DispatchQueue,
        handler: @escaping AppleVideoDatagramHandler
    ) {
        var readBuffer = PacketReadBuffer()
        while true {
            guard let received = Self.receive(packet: packet, using: &readBuffer) else { return }
            let expectedTarget = lock.withTailscaleMediaLock {
                guard videoTargets.indices.contains(mediaStreamIndex) else { return "" }
                return videoTargets[mediaStreamIndex]
            }
            guard received.remoteAddress == expectedTarget else { continue }
            refreshNetworkPathIfNeeded(at: received.readCompletedAt)
            let path = lock.withTailscaleMediaLock { networkPath }
            let ingressAge = min(received.ingressAge, received.readCompletedAt)
            let arrivalTime = received.readCompletedAt - ingressAge
            let datagram = AppleReceivedVideoDatagram(
                data: received.data,
                arrivalTime: arrivalTime,
                receiveBatchStartedAt: received.readCompletedAt,
                estimatedSocketBacklogBytes: 0,
                ingressAge: ingressAge,
                receiveBufferOverflowCount: received.receiveBufferOverflowCount,
                networkPath: path
            )
            deliveryQueue.sync {
                let isOpen = lock.withTailscaleMediaLock { !isClosed }
                if isOpen { handler(datagram) }
            }
        }
    }

    private static func receive(
        packet: TailscalePacketConnection,
        using buffer: inout PacketReadBuffer
    ) -> ReceivedPacket? {
        var received = 0
        var ingressAgeNanoseconds: UInt64 = 0
        var receiveBufferOverflowCount: UInt64 = 0
        let result = buffer.data.withUnsafeMutableBytes { bytes in
            buffer.remoteAddress.withUnsafeMutableBufferPointer { remote in
                tailscale_packet_read_ex(
                    packet,
                    bytes.baseAddress,
                    bytes.count,
                    &received,
                    remote.baseAddress,
                    remote.count,
                    &ingressAgeNanoseconds,
                    &receiveBufferOverflowCount
                )
            }
        }
        guard result == 0 else { return nil }
        let readCompletedAt = CACurrentMediaTime()
        return ReceivedPacket(
            data: Data(buffer.data.prefix(received)),
            remoteAddress: String(cString: buffer.remoteAddress),
            readCompletedAt: readCompletedAt,
            ingressAge: TimeInterval(ingressAgeNanoseconds) / 1_000_000_000,
            receiveBufferOverflowCount: receiveBufferOverflowCount
        )
    }

    private func refreshNetworkPathIfNeeded(at now: TimeInterval) {
        let shouldRefresh = lock.withTailscaleMediaLock { () -> Bool in
            guard !isClosed,
                  !isNetworkPathRefreshInFlight,
                  now - lastNetworkPathRefreshAt >= Self.networkPathRefreshInterval else {
                return false
            }
            lastNetworkPathRefreshAt = now
            isNetworkPathRefreshInFlight = true
            return true
        }
        guard shouldRefresh else { return }
        let nodeProvider = nodeProvider
        let remoteHost = remoteHost
        Task { [weak self] in
            let path = await nodeProvider.tailscaleVideoNetworkPath(to: remoteHost)
            self?.lock.withTailscaleMediaLock {
                guard let self else { return }
                self.isNetworkPathRefreshInFlight = false
                if !self.isClosed, let path {
                    self.networkPath = path
                }
            }
        }
    }

    private func send(
        _ datagram: Data,
        packet: TailscalePacketConnection,
        target: String
    ) throws {
        let result = datagram.withUnsafeBytes { bytes in
            target.withCString {
                tailscale_packet_write(packet, bytes.baseAddress, bytes.count, $0)
            }
        }
        guard result == 0 else {
            throw AppleMediaReceiverError.sendFailed(result)
        }
    }

    private static func openPacket(
        tailscaleHandle: TailscaleHandle,
        localAddress: String
    ) throws -> TailscalePacketConnection {
        var packet: TailscalePacketConnection = 0
        let result = tailscale_packet_open(
            tailscaleHandle,
            NetProtocol.udp.rawValue,
            localAddress,
            &packet
        )
        guard result == 0 else {
            throw TailscaleMediaReceiverError.openFailed(errorMessage(for: tailscaleHandle))
        }
        return packet
    }

    private static func errorMessage(for handle: TailscaleHandle) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        guard tailscale_errmsg(handle, &buffer, buffer.count) == 0 else {
            return "Embedded Tailscale UDP setup failed."
        }
        return String(cString: buffer)
    }
}

enum TailscaleMediaReceiverError: LocalizedError {
    case missingLocalAddress
    case openFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingLocalAddress:
            "The embedded Tailscale node has no compatible local address."
        case .openFailed(let message):
            "The embedded Tailscale media connection could not be prepared. \(message)"
        }
    }
}

private extension NSLock {
    func withTailscaleMediaLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

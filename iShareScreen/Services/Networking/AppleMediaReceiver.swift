import Darwin
import Foundation

final class AppleMediaReceiver: @unchecked Sendable {
    private static let maximumQueuedPackets = 16_384
    private static let maximumDatagramLength = 65_535

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.isharescreen.media-receiver")
    private let controlSocket: Int32
    private let videoSocket: Int32
    private let controlSource: DispatchSourceRead
    private let videoSource: DispatchSourceRead
    private let punchTimer: DispatchSourceTimer
    private var controlPackets = [Data]()
    private var videoPackets = [Data]()
    private var isClosed = false

    init(endpoint: ConnectionEndpoint) throws {
        guard endpoint.port < UInt16.max else { throw AppleMediaReceiverError.invalidPort }
        let remoteAddress = try Self.resolveIPv4(endpoint.host)
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

        controlSource = DispatchSource.makeReadSource(fileDescriptor: controlSocket, queue: queue)
        videoSource = DispatchSource.makeReadSource(fileDescriptor: videoSocket, queue: queue)
        punchTimer = DispatchSource.makeTimerSource(queue: queue)

        controlSource.setEventHandler { [weak self] in self?.drain(self?.controlSocket, isVideo: false) }
        videoSource.setEventHandler { [weak self] in self?.drain(self?.videoSocket, isVideo: true) }
        controlSource.setCancelHandler { [controlSocket] in Darwin.close(controlSocket) }
        videoSource.setCancelHandler { [videoSocket] in Darwin.close(videoSocket) }
        punchTimer.setEventHandler { [weak self] in self?.punch() }
        punchTimer.schedule(deadline: .now(), repeating: .milliseconds(100))
        controlSource.activate()
        videoSource.activate()
        punchTimer.activate()
    }

    var queuedVideoPacketCount: Int {
        lock.withLock { videoPackets.count }
    }

    func drainVideoPackets() -> [Data] {
        lock.withLock {
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
    }

    deinit {
        close()
    }

    private func punch() {
        var byte: UInt8 = 0
        _ = Darwin.send(controlSocket, &byte, 1, 0)
        _ = Darwin.send(videoSocket, &byte, 1, 0)
    }

    private func drain(_ socket: Int32?, isVideo: Bool) {
        guard let socket else { return }
        var buffer = [UInt8](repeating: 0, count: Self.maximumDatagramLength)
        while true {
            let count = Darwin.recv(socket, &buffer, buffer.count, MSG_DONTWAIT)
            guard count > 0 else { break }
            let packet = Data(buffer.prefix(count))
            lock.withLock {
                if isVideo {
                    if videoPackets.count == Self.maximumQueuedPackets {
                        videoPackets.removeFirst(Self.maximumQueuedPackets / 4)
                    }
                    videoPackets.append(packet)
                } else {
                    if controlPackets.count == Self.maximumQueuedPackets {
                        controlPackets.removeFirst(Self.maximumQueuedPackets / 4)
                    }
                    controlPackets.append(packet)
                }
            }
        }
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

            var remote = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: remotePort.bigEndian,
                sin_addr: remoteAddress,
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            let connectResult = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else { throw AppleMediaReceiverError.connectionFailed(errno) }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
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
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

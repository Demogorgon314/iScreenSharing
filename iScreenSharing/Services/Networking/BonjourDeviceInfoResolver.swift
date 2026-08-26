import dnssd
import Foundation

protocol BonjourDeviceInfoResolving: Sendable {
    func deviceInfo(for endpoint: ConnectionEndpoint) async -> AppleRemoteDeviceInfo?
}

struct BonjourDeviceInfoResolver: BonjourDeviceInfoResolving {
    private let queue = DispatchQueue(label: "com.isharescreen.bonjour-device-info")

    func deviceInfo(for endpoint: ConnectionEndpoint) async -> AppleRemoteDeviceInfo? {
        guard let service = endpoint.bonjourService,
              let fullName = Self.deviceInfoFullName(for: service) else { return nil }
        let query = BonjourDeviceInfoQuery(fullName: fullName, queue: queue)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { query.start(continuation: continuation) }
            }
        } onCancel: {
            queue.async { query.cancel() }
        }
    }

    private static func deviceInfoFullName(for service: BonjourServiceEndpoint) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        let error = service.name.withCString { name in
            service.domain.withCString { domain in
                DNSServiceConstructFullName(
                    &buffer,
                    name,
                    "_device-info._tcp",
                    domain
                )
            }
        }
        guard error == kDNSServiceErr_NoError else { return nil }
        return String(cString: buffer)
    }
}

enum BonjourDeviceInfoTXT {
    static func parse(_ data: Data) -> AppleRemoteDeviceInfo? {
        guard !data.isEmpty, data.count <= 4_096 else { return nil }
        var values = [String: String]()
        var offset = 0
        while offset < data.count {
            let length = Int(data[offset])
            offset += 1
            guard length > 0, offset <= data.count - length,
                  let entry = String(data: data[offset..<(offset + length)], encoding: .utf8) else {
                return nil
            }
            offset += length
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            values[String(parts[0]).lowercased()] = String(parts[1])
        }

        guard let model = values["model"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return nil }
        return AppleRemoteDeviceInfo(
            modelIdentifier: model,
            deviceColor: values["icolor"],
            enclosureColor: values["ecolor"]
        )
    }
}

private final class BonjourDeviceInfoQuery: @unchecked Sendable {
    private let fullName: String
    private let queue: DispatchQueue
    private var continuation: CheckedContinuation<AppleRemoteDeviceInfo?, Never>?
    private var serviceRef: DNSServiceRef?
    private var isFinished = false

    init(fullName: String, queue: DispatchQueue) {
        self.fullName = fullName
        self.queue = queue
    }

    func start(continuation: CheckedContinuation<AppleRemoteDeviceInfo?, Never>) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else {
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation

        var reference: DNSServiceRef?
        let flags = DNSServiceFlags(kDNSServiceFlagsTimeout | kDNSServiceFlagsIncludeP2P)
        let error = fullName.withCString { name in
            DNSServiceQueryRecord(
                &reference,
                flags,
                0,
                name,
                UInt16(kDNSServiceType_TXT),
                UInt16(kDNSServiceClass_IN),
                bonjourDeviceInfoQueryReply,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
        guard error == kDNSServiceErr_NoError, let reference else {
            finish(with: nil)
            return
        }
        serviceRef = reference
        guard DNSServiceSetDispatchQueue(reference, queue) == kDNSServiceErr_NoError else {
            finish(with: nil)
            return
        }
    }

    func receive(error: DNSServiceErrorType, bytes: Data?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard error == kDNSServiceErr_NoError, let bytes else {
            finish(with: nil)
            return
        }
        finish(with: BonjourDeviceInfoTXT.parse(bytes))
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(queue))
        finish(with: nil)
    }

    private func finish(with info: AppleRemoteDeviceInfo?) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isFinished else { return }
        isFinished = true
        if let serviceRef {
            DNSServiceRefDeallocate(serviceRef)
            self.serviceRef = nil
        }
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: info)
    }
}

private let bonjourDeviceInfoQueryReply: DNSServiceQueryRecordReply = {
    _, _, _, error, _, _, _, length, rawData, _, context in
    guard let context else { return }
    let query = Unmanaged<BonjourDeviceInfoQuery>.fromOpaque(context).takeUnretainedValue()
    let data = rawData.map { Data(bytes: $0, count: Int(length)) }
    query.receive(error: error, bytes: data)
}

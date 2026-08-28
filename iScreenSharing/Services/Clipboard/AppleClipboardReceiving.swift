import Foundation

@MainActor
protocol AppleClipboardReceiving: AnyObject {
    var allowsRemoteSynchronization: Bool { get }
    func localArchive() -> AppleClipboardArchive?
    func archiveForRemoteRequest() -> AppleClipboardArchive?
    func remoteRequestDidFinish()
    func remotePasteboardDidChange()
    func receive(_ archive: AppleClipboardArchive)
    func synchronizationLease() -> UInt64?
    func isSynchronizationLeaseValid(_ lease: UInt64) -> Bool
    func receiveIfEligible(_ archive: AppleClipboardArchive, lease: UInt64) -> Bool
    func setControlling(_ controlling: Bool)
    func close()
}

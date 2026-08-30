import Darwin
import Foundation

enum AppleFileCatalogMetadata {
    private typealias PathMakeReference = @convention(c) (
        UnsafePointer<UInt8>?,
        UnsafeMutableRawPointer?,
        UnsafeMutablePointer<UInt8>?
    ) -> Int32
    private typealias GetCatalogInfo = @convention(c) (
        UnsafeRawPointer?,
        UInt32,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?
    ) -> Int16
    private typealias SetCatalogInfo = @convention(c) (
        UnsafeRawPointer?,
        UInt32,
        UnsafeRawPointer?
    ) -> Int16

    private struct API {
        let pathMakeReference: PathMakeReference
        let getCatalogInfo: GetCatalogInfo
        let setCatalogInfo: SetCatalogInfo

        init?() {
            let path = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/"
                + "CarbonCore.framework/Versions/A/CarbonCore"
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
                return nil
            }
            guard let pathMakeReference = dlsym(handle, "FSPathMakeRef"),
                  let getCatalogInfo = dlsym(handle, "FSGetCatalogInfo"),
                  let setCatalogInfo = dlsym(handle, "FSSetCatalogInfo") else {
                dlclose(handle)
                return nil
            }
            // CarbonCore is held for the process lifetime. These are public,
            // deprecated APIs whose structs are no longer imported by Swift.
            self.pathMakeReference = unsafeBitCast(
                pathMakeReference,
                to: PathMakeReference.self
            )
            self.getCatalogInfo = unsafeBitCast(
                getCatalogInfo,
                to: GetCatalogInfo.self
            )
            self.setCatalogInfo = unsafeBitCast(
                setCatalogInfo,
                to: SetCatalogInfo.self
            )
        }
    }

    private static let api = API()
    private static let nodeFlagsBitmap: UInt32 = 0x0000_0002
    private static let fileReferenceByteCount = 80
    private static let catalogInfoByteCount = 148

    static func nodeFlags(at url: URL) -> UInt16? {
        guard let api, var reference = fileReference(at: url, api: api) else {
            return nil
        }
        var catalogInfo = [UInt64](
            repeating: 0,
            count: alignedWordCount(for: catalogInfoByteCount)
        )
        return reference.withUnsafeMutableBytes { referenceBytes in
            catalogInfo.withUnsafeMutableBytes { catalogBytes in
                guard api.getCatalogInfo(
                    referenceBytes.baseAddress,
                    nodeFlagsBitmap,
                    catalogBytes.baseAddress,
                    nil,
                    nil,
                    nil
                ) == 0 else { return nil }
                return catalogBytes.load(as: UInt16.self)
            }
        }
    }

    static func setNodeFlags(_ nodeFlags: UInt16, at url: URL) -> Bool {
        guard let api, var reference = fileReference(at: url, api: api) else {
            return false
        }
        var catalogInfo = [UInt64](
            repeating: 0,
            count: alignedWordCount(for: catalogInfoByteCount)
        )
        return reference.withUnsafeMutableBytes { referenceBytes in
            catalogInfo.withUnsafeMutableBytes { catalogBytes in
                catalogBytes.storeBytes(of: nodeFlags, as: UInt16.self)
                return api.setCatalogInfo(
                    referenceBytes.baseAddress,
                    nodeFlagsBitmap,
                    catalogBytes.baseAddress
                ) == 0
            }
        }
    }

    private static func fileReference(at url: URL, api: API) -> [UInt64]? {
        var reference = [UInt64](
            repeating: 0,
            count: alignedWordCount(for: fileReferenceByteCount)
        )
        let result = reference.withUnsafeMutableBytes { referenceBytes in
            url.path.withCString { path in
                api.pathMakeReference(
                    UnsafeRawPointer(path).assumingMemoryBound(to: UInt8.self),
                    referenceBytes.baseAddress,
                    nil
                )
            }
        }
        return result == 0 ? reference : nil
    }

    private static func alignedWordCount(for byteCount: Int) -> Int {
        (byteCount + MemoryLayout<UInt64>.size - 1) / MemoryLayout<UInt64>.size
    }
}

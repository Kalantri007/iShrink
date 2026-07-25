// iShrink Phase 1 plan, U3 "Library scanner & asset sizing".
//
// Streams `AssetRecord`s from a `PhotoLibraryProviding` source to a
// caller-provided sink, driven purely through the protocol so tests run
// against `FakeLibrary` — no real PhotoKit/TCC needed (plan verification).

/// Reported after each page is scanned.
public struct ScanProgress: Sendable, Equatable {
    /// Records yielded so far (cumulative).
    public let scanned: Int
    /// Total records in the library scope, as reported by
    /// `PhotoLibraryProviding.assetCount` at the start of the scan.
    public let total: Int
}

/// Paged, memory-bounded scan over a `PhotoLibraryProviding` conformer.
///
/// `scan(onRecord:onProgress:)` never buffers more than one page
/// (`pageSize` records) at a time: it asks the library for one page, yields
/// each record in it to `onRecord`, reports progress, then asks for the
/// next page — it never asks for "everything" in one call (plan R9: "never
/// buffers the whole library in memory").
public struct LibraryScanner: Sendable {
    private let library: PhotoLibraryProviding
    private let pageSize: Int

    /// - Parameters:
    ///   - library: the protocol seam (`PhotoKitLibrary` in production,
    ///     `FakeLibrary` in tests).
    ///   - pageSize: how many records to request per page. Kept small and
    ///     constant regardless of library size — a 100k-asset library is
    ///     scanned in ~100k/pageSize page fetches, never one giant fetch.
    public init(library: PhotoLibraryProviding, pageSize: Int = 200) {
        precondition(pageSize > 0, "pageSize must be positive")
        self.library = library
        self.pageSize = pageSize
    }

    /// Scans the whole library in order, invoking `onRecord` once per asset
    /// and `onProgress` once per page (if provided).
    public func scan(
        onRecord: @Sendable (AssetRecord) async -> Void,
        onProgress: (@Sendable (ScanProgress) async -> Void)? = nil
    ) async {
        let total = await library.assetCount
        var offset = 0
        var scanned = 0

        while true {
            let page = await library.fetchRecords(offset: offset, limit: pageSize)
            if page.isEmpty {
                break
            }

            for record in page {
                await onRecord(record)
            }

            scanned += page.count
            offset += page.count
            await onProgress?(ScanProgress(scanned: scanned, total: total))

            if page.count < pageSize || offset >= total {
                // A short page, or having reached the known total, both mean
                // end of library — either check avoids one extra empty
                // fetch (short page: last page wasn't full; reached total:
                // last page was exactly full).
                break
            }
        }
    }
}

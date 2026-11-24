import ClipboardKit
import Foundation
import Testing
@testable import PasteCore

private func link(_ url: String) -> ClipSnapshot {
    ClipSnapshot(items: [ClipItemSnapshot(representations: [ClipRepresentation(type: ClipType.plainText, data: Data(url.utf8))])])
}

private let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEElEQVR4nGP4z8DwHwQZYAwAR8oH+Rq28akAAAAASUVORK5CYII=")!

private func tempStore() throws -> (HistoryStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xpaste-link-\(UUID().uuidString)")
    return (try HistoryStore(directory: directory), directory)
}

/// 记录被访问过的地址的假取回器。
private actor FakeFetcher {
    private(set) var requested: [URL] = []
    var failing = false

    func setFailing(_ value: Bool) { failing = value }

    func fetch(_ url: URL) throws -> LinkMetadata {
        requested.append(url)
        if failing { throw URLError(.notConnectedToInternet) }
        return LinkMetadata(title: "Title of \(url.host() ?? "")", image: tinyPNG, imageKind: .image)
    }
}

@Suite struct LinkPolicyTests {
    @Test func publicAddressesAreFetchable() {
        for url in ["https://example.com/", "http://www.wikipedia.org/wiki/A?b=c", "https://8.8.8.8/", "https://[2606:4700::1111]/", " https://a.b.io \n"] {
            #expect(LinkPolicy.fetchableURL(url) != nil, "\(url)")
        }
    }

    @Test func localAndPrivateAddressesAreNot() {
        let blocked = [
            "http://localhost/", "http://localhost:8080/x", "http://foo.localhost/", "http://printer.local/", "http://nas/", "http://wiki.corp/",
            "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/", "http://0.0.0.0/",
            "http://10.1.82.39/", "http://172.16.0.1/", "http://172.31.255.255/", "http://192.168.1.1/", "http://169.254.169.254/latest/meta-data",
            "http://100.64.0.1/", "http://224.0.0.1/", "http://[::1]/", "http://[fe80::1]/", "http://[fd00::1]/", "http://[::ffff:192.168.1.1]/",
            "ftp://example.com/", "file:///etc/passwd", "javascript:alert(1)", "https://user:pw@example.com/", "not a url", "",
        ]
        for url in blocked { #expect(LinkPolicy.fetchableURL(url) == nil, "\(url)") }
    }

    @Test func resolvedAddressCheck() {
        #expect(LinkPolicy.isPublicAddress("93.184.216.34"))
        #expect(LinkPolicy.isPublicAddress("172.32.0.1"))
        #expect(!LinkPolicy.isPublicAddress("192.168.0.10"))
        #expect(!LinkPolicy.isPublicAddress("fe80::1%en0"))
        #expect(!LinkPolicy.isPublicAddress("garbage"))
    }
}

@Suite struct LinkMetadataTests {
    @Test func metadataShowsOnSummaryAndIsSearchable() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try store.record(link("https://example.com/page"))
        #expect(clip.kind == .link)
        #expect(clip.linkTitle == nil && clip.linkImage == .none)

        let job = try #require(try store.nextLinkAwaitingMetadata())
        #expect(job.id == clip.id && job.url == "https://example.com/page")
        #expect(try store.setLinkMetadata(LinkMetadata(title: " Quarterly Roadmap ", image: tinyPNG, imageKind: .icon), for: job))

        let updated = try #require(try store.summary(id: clip.id))
        #expect(updated.linkTitle == "Quarterly Roadmap")
        #expect(updated.linkImage == .icon && updated.thumbnail != nil)
        #expect(try store.clips(matching: ClipQuery(text: "Roadmap")).map(\.id) == [clip.id])
        #expect(try store.nextLinkAwaitingMetadata() == nil)
        // 改名后标题仍在索引里。
        try store.setTitle("mine", for: clip.id)
        #expect(try store.clips(matching: ClipQuery(text: "Roadmap")).count == 1)
        #expect(try store.integrityReport().isClean)
    }

    @Test func undecodableImageIsDropped() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.record(link("https://example.com/"))
        let job = try #require(try store.nextLinkAwaitingMetadata())
        try store.setLinkMetadata(LinkMetadata(title: nil, image: Data("not an image".utf8), imageKind: .image), for: job)
        let clip = try #require(try store.clips().first)
        #expect(clip.linkImage == .none && clip.thumbnail == nil && clip.linkTitle == nil)
    }

    @Test func lateResultForDeletedLinkIsNotWritten() throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try store.record(link("https://example.com/"))
        let job = try #require(try store.nextLinkAwaitingMetadata())
        try store.removeFromHistory(ids: [clip.id])
        #expect(try store.setLinkMetadata(LinkMetadata(title: "Late"), for: job) == false)
        #expect(try store.clips(matching: ClipQuery(text: "Late")).isEmpty)
        #expect(try store.integrityReport().isClean)
    }
}

@Suite struct LinkIndexerTests {
    @Test func fetchesNewestFirstAndSkipsPrivateAddresses() async throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        try store.record(link("https://one.example.com/"), now: t0)
        try store.record(link("http://192.168.1.1/admin"), now: t0 + 1)
        try store.record(link("http://localhost:3000/"), now: t0 + 2)
        try store.record(link("https://two.example.com/"), now: t0 + 3)
        let fake = FakeFetcher()
        let changes = Counter()
        let indexer = LinkIndexer(store: store, onChange: { changes.increment() }) { try await fake.fetch($0) }

        await indexer.kick()
        await indexer.waitUntilIdle()

        #expect(await fake.requested.map(\.absoluteString) == ["https://two.example.com/", "https://one.example.com/"])
        #expect(changes.value == 2)
        #expect(try store.nextLinkAwaitingMetadata() == nil)
        #expect(try store.clips(matching: ClipQuery(text: "Title of")).count == 2)
    }

    @Test func disabledMeansNoRequests() async throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.record(link("https://example.com/"))
        let fake = FakeFetcher()
        let indexer = LinkIndexer(store: store, isEnabled: { false }) { try await fake.fetch($0) }

        await indexer.kick()
        await indexer.waitUntilIdle()

        #expect(await fake.requested.isEmpty)
        // 开关打开后还能补上。
        #expect(try store.nextLinkAwaitingMetadata() != nil)
    }

    @Test func disablingDuringFetchRejectsLateMetadata() async throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try store.record(link("https://example.com/"))
        let flag = EnabledFlag()
        let fetcher = GatedFetcher()
        let indexer = LinkIndexer(store: store, isEnabled: { flag.value }) { _ in try await fetcher.fetch() }
        await indexer.kick()
        await fetcher.waitForStart()
        flag.value = false
        await fetcher.release()
        await indexer.waitUntilIdle()
        #expect(try store.summary(id: clip.id)?.linkTitle == nil)
        #expect(try store.nextLinkAwaitingMetadata() != nil)
    }

    @Test func immediateReenableWaitsForCancelledFetchAndResumes() async throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.record(link("https://example.com/"))
        let flag = EnabledFlag()
        let fetcher = GatedFetcher()
        let indexer = LinkIndexer(store: store, isEnabled: { flag.value }) { _ in try await fetcher.fetch() }
        await indexer.kick()
        await fetcher.waitForStart()
        flag.value = false
        await indexer.settingsDidChange()
        flag.value = true
        async let restarted: Void = indexer.settingsDidChange()
        await fetcher.release()
        await restarted
        await indexer.waitUntilIdle()
        #expect(await fetcher.calls == 2)
        #expect(try store.clips().first?.linkTitle == "result 2")
    }

    @Test func cancelledProviderErrorRemainsRetryable() async throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.record(link("https://example.com/"))
        let flag = EnabledFlag()
        let fetcher = GatedFetcher(throwsOnFirst: true)
        let indexer = LinkIndexer(store: store, isEnabled: { flag.value }) { _ in try await fetcher.fetch() }
        await indexer.kick()
        await fetcher.waitForStart()
        flag.value = false
        await indexer.settingsDidChange()
        await fetcher.release()
        await indexer.waitUntilIdle()
        flag.value = true
        await indexer.settingsDidChange()
        await indexer.waitUntilIdle()
        #expect(await fetcher.calls == 2)
        #expect(try store.clips().first?.linkTitle == "result 2")
    }

    @Test func failedFetchIsNotRetriedInSameRunButStaysPending() async throws {
        let (store, directory) = try tempStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.record(link("https://example.com/"))
        let fake = FakeFetcher()
        await fake.setFailing(true)
        let indexer = LinkIndexer(store: store) { try await fake.fetch($0) }

        await indexer.kick()
        await indexer.waitUntilIdle()
        await indexer.kick()
        await indexer.waitUntilIdle()

        #expect(await fake.requested.count == 1)
        #expect(try store.nextLinkAwaitingMetadata() != nil)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class EnabledFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true
    var value: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
}

/// 第一条请求故意不响应取消，用于模拟已经开始、较晚才返回的网络请求。
private actor GatedFetcher {
    private(set) var calls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private let throwsOnFirst: Bool
    init(throwsOnFirst: Bool = false) { self.throwsOnFirst = throwsOnFirst }
    func fetch() async throws -> LinkMetadata {
        calls += 1
        let call = calls
        if call == 1 {
            await withCheckedContinuation { continuation in
                gate = continuation
                started?.resume()
                started = nil
            }
        }
        if call == 1 && throwsOnFirst { throw URLError(.cancelled) }
        return LinkMetadata(title: "result \(call)")
    }
    func waitForStart() async {
        if gate != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() {
        gate?.resume()
        gate = nil
    }
}

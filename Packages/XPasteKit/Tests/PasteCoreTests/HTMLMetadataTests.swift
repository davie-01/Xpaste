import Foundation
import Testing
@testable import PasteCore

@Suite struct HTMLMetadataTests {
    let page = URL(string: "https://example.com/articles/42?ref=x")!

    @Test func prefersOpenGraphAndResolvesRelativeAddresses() {
        let html = """
            <html><head>
            <title> Plain  title
            </title>
            <meta property="og:title" content="Fish &amp; Chips &#8212; &#x4E2D;文">
            <META NAME='twitter:image' CONTENT='/img/tw.png'>
            <meta property="og:image" content="//cdn.example.com/cover.jpg">
            <link rel="icon" href="favicon-32.png">
            <link rel="apple-touch-icon" href="/touch.png">
            </head><body><title>not this</title></body></html>
            """
        let metadata = HTMLMetadata(html: html, baseURL: page)
        #expect(metadata.title == "Fish & Chips — 中文")
        #expect(metadata.images.map(\.absoluteString) == ["https://cdn.example.com/cover.jpg", "https://example.com/img/tw.png"])
        #expect(metadata.icons.map(\.absoluteString) == ["https://example.com/touch.png", "https://example.com/articles/favicon-32.png", "https://example.com/favicon.ico"])
    }

    @Test func fallsBackToTitleTagAndBaseHref() {
        let html = #"<head><base href="https://static.example.org/s/"><title>Only &lt;title&gt;</title><link rel="shortcut icon" href="i.ico"></head>"#
        let metadata = HTMLMetadata(html: html, baseURL: page)
        #expect(metadata.title == "Only <title>")
        #expect(metadata.images.isEmpty)
        #expect(metadata.icons.first?.absoluteString == "https://static.example.org/s/i.ico")
    }

    @Test func emptyPageStillOffersTheRootFavicon() {
        let metadata = HTMLMetadata(html: "<p>nothing</p>", baseURL: page)
        #expect(metadata.title == nil && metadata.images.isEmpty)
        #expect(metadata.icons.map(\.absoluteString) == ["https://example.com/favicon.ico"])
    }
}

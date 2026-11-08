import Testing
import CaptureCore

@Suite struct LinkIdentityTests {
    @Test func trackingParametersDoNotMakeANewLink() {
        #expect(LinkIdentity.key("https://www.instagram.com/reel/REEL0000001/")
                == LinkIdentity.key("https://www.instagram.com/reel/REEL0000001/?l=1"))
        #expect(LinkIdentity.key("https://example.com/a?utm_source=x&utm_medium=y")
                == LinkIdentity.key("https://example.com/a"))
        #expect(LinkIdentity.key("https://youtu.be/abc?si=XYZ") == LinkIdentity.key("https://youtu.be/abc"))
        #expect(LinkIdentity.key("https://EXAMPLE.com/a?fbclid=1") == LinkIdentity.key("https://example.com/a"))
    }

    @Test func meaningfulParametersStayDistinct() {
        #expect(LinkIdentity.key("https://youtube.com/watch?v=A") != LinkIdentity.key("https://youtube.com/watch?v=B"))
        // `l` is only Instagram's share marker; elsewhere it may matter.
        #expect(LinkIdentity.key("https://example.com/a?l=1") != LinkIdentity.key("https://example.com/a"))
        #expect(LinkIdentity.key("https://example.com/a") != LinkIdentity.key("https://example.com/b"))
    }

    @Test func deduplicatedKeepsTheFirstOfEachLinkInOrder() {
        let urls = [
            CapturedURL(url: "https://www.instagram.com/reel/X/", source: "shared_payload"),
            CapturedURL(url: "https://example.com/b", source: "shared_payload"),
            CapturedURL(url: "https://www.instagram.com/reel/X/?l=1", source: "shared_payload"),
        ]
        #expect(LinkIdentity.deduplicated(urls).map(\.url)
                == ["https://www.instagram.com/reel/X/", "https://example.com/b"])
    }
}

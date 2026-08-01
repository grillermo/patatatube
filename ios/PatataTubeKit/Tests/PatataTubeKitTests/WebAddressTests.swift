import Foundation
import Testing
@testable import PatataTubeKit

struct WebAddressTests {
    @Test func keepsAnExplicitScheme() {
        #expect(WebAddress.resolve("https://awh.chiq.me/live")?.absoluteString
                == "https://awh.chiq.me/live")
        #expect(WebAddress.resolve("http://example.com")?.absoluteString
                == "http://example.com")
    }

    @Test func fillsHTTPSForABareHost() {
        #expect(WebAddress.resolve("awh.chiq.me")?.absoluteString
                == "https://awh.chiq.me")
    }

    @Test func fillsHTTPSForABareHostWithPath() {
        #expect(WebAddress.resolve("awh.chiq.me/live")?.absoluteString
                == "https://awh.chiq.me/live")
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(WebAddress.resolve("  awh.chiq.me/live  ")?.absoluteString
                == "https://awh.chiq.me/live")
    }

    @Test func rejectsTextWithoutAHost() {
        #expect(WebAddress.resolve("cat videos") == nil)
        #expect(WebAddress.resolve("") == nil)
        #expect(WebAddress.resolve("   ") == nil)
        #expect(WebAddress.resolve("localpage") == nil)
    }

    @Test func typedAddressBeatsTheTopHistoryMatch() {
        #expect(WebAddress.destination(for: "example.com/new",
                                       topMatch: "https://example.com/old")?.absoluteString
                == "https://example.com/new")
        #expect(WebAddress.destination(for: "https://other.test",
                                       topMatch: "https://awh.chiq.me/live")?.absoluteString
                == "https://other.test")
    }

    @Test func fallsBackToTheTopHistoryMatchForNonAddresses() {
        #expect(WebAddress.destination(for: "awh live",
                                       topMatch: "https://awh.chiq.me/live")?.absoluteString
                == "https://awh.chiq.me/live")
        #expect(WebAddress.destination(for: "localpage",
                                       topMatch: "https://awh.chiq.me/live")?.absoluteString
                == "https://awh.chiq.me/live")
    }

    @Test func resolvesToNothingWhenNeitherApplies() {
        #expect(WebAddress.destination(for: "cat videos", topMatch: nil) == nil)
        #expect(WebAddress.destination(for: "", topMatch: nil) == nil)
    }
}

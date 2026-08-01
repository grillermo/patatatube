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
}

import Foundation
import Testing
import MatineeKit

/// YouTube's feed and Google's suggestions answer with cookies; a stored cookie sent back would tie every feed
/// refresh and every typed search together.
@Test func privateSessionKeepsNoCookies() {
    let config = PrivateHTTP.session.configuration
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
    #expect(config.httpCookieAcceptPolicy == .never)
    #expect(config.urlCredentialStorage == nil)
}

@Test func thumbnailConfigurationKeepsItsCacheButNoCookies() {
    let cache = URLCache.shared
    let config = PrivateHTTP.configuration(cache: cache)
    #expect(config.urlCache === cache)
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
}

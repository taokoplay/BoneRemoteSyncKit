import Foundation
import Testing
import BoneRemoteSyncCore

@Suite struct RemoteSyncErrorDisplayTests {
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 1e300, -1, Double(Int.max)])
    func invalidRetryIntervalCanBeDisplayedWithoutTrap(value: Double) {
        #expect(RemoteSyncError.rateLimited(retryAfter: value).description == "触发限流")
    }

    @Test func validRetryIntervalIsDisplayed() {
        #expect(RemoteSyncError.rateLimited(retryAfter: 7).description == "触发限流，7 秒后重试")
        #expect(RemoteSyncError.rateLimited(retryAfter: 0).description == "触发限流，0 秒后重试")
        #expect(RemoteSyncError.rateLimited(retryAfter: nil).description == "触发限流")
    }
}

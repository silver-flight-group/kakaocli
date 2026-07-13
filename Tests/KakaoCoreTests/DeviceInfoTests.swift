import Testing
@testable import KakaoCore

@Test func testSHA512HexMatchesKnownValue() {
    // SHA-512("0") is the "empty account" hash KakaoTalk stores for logged-out slots.
    let expected = "31bca02094eb78126a517b206a88c73cfa9ec6f704c7030d18212cace820f025f00bf0ea68dbf3f3a5436ca63b53bf7bf80ad8d5de7d8359d0b7fed9dbc3ab99"
    #expect(DeviceInfo.sha512Hex("0") == expected)
}

@Test func testRecoverUserIdRoundTrip() {
    // A userId hashed with SHA-512 must be recoverable by the brute-force search.
    let id = 396512
    let hash = DeviceInfo.sha512Hex(String(id))
    let recovered = DeviceInfo.recoverUserIdFromSHA512(hexHash: hash, timeout: 30, maxId: 1_000_000)
    #expect(recovered == id)
}

@Test func testRecoverUserIdReturnsNilWhenNotInRange() {
    // Pre-image lies outside maxId — search should exhaust and return nil, not hang.
    let hash = DeviceInfo.sha512Hex("999999")
    let recovered = DeviceInfo.recoverUserIdFromSHA512(hexHash: hash, timeout: 5, maxId: 1000)
    #expect(recovered == nil)
}

@Test func testRecoverUserIdRejectsMalformedHash() {
    #expect(DeviceInfo.recoverUserIdFromSHA512(hexHash: "deadbeef") == nil)
}

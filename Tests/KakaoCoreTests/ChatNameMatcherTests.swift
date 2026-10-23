import Testing
@testable import KakaoCore

private typealias C = ChatNameMatcher.Candidate

// Mirrors a real chat list: one 1:1 chat and two group chats containing the name.
private let chats = [
    C(name: "주의 평강을 시연하다.", isGroup: true),
    C(name: "강순미爱人, 강순애, 강연, 김흥옥 동서 길융.", isGroup: true),
    C(name: "강순미爱人", isGroup: false),
    C(name: "동대전3(강순미)", isGroup: true),
]

@Test func testPersonNamePrefersSingleDirectChat() {
    #expect(ChatNameMatcher.pick("강순미", from: chats) == .found(2))
}

@Test func testExactNameWins() {
    #expect(ChatNameMatcher.pick("동대전3(강순미)", from: chats) == .found(3))
}

@Test func testSingleSubstringMatch() {
    #expect(ChatNameMatcher.pick("평강", from: chats) == .found(0))
}

@Test func testNotFound() {
    #expect(ChatNameMatcher.pick("없는사람", from: chats) == .notFound)
}

@Test func testMultipleGroupMatchesAreAmbiguous() {
    let groups = [C(name: "민수 가족방", isGroup: true), C(name: "민수 회사", isGroup: true)]
    #expect(ChatNameMatcher.pick("민수", from: groups) == .ambiguous(["민수 가족방", "민수 회사"]))
}

@Test func testMultipleDirectMatchesAreAmbiguous() {
    let directs = [C(name: "김민수", isGroup: false), C(name: "이민수", isGroup: false)]
    #expect(ChatNameMatcher.pick("민수", from: directs) == .ambiguous(["김민수", "이민수"]))
}

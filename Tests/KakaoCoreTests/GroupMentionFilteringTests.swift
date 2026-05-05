import Testing
@testable import KakaoCore

@Test func testBuildMentionContainsLikePatternWrapsAndEscapesWildcards() {
    let reader = DatabaseReader(databasePath: "/tmp/unused")
    let pattern = reader.buildMentionContainsLikePattern("@clo_%")
    #expect(pattern == #"%@clo\_\%%"#)
}

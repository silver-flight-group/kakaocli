import Testing
@testable import KakaoCore

@Test func testAddPasswordCommandEscapesQuotesAndBackslashes() throws {
    let cmd = try CredentialStore.addPasswordCommand(service: "svc", account: "acct", value: #"a"b\c d"#)
    #expect(cmd == #"add-generic-password -s svc -a acct -U -w "a\"b\\c d""# + "\n")
}

@Test func testParsePasswordLineASCII() {
    // Real `security -g` output: quotes inside the value are not escaped.
    #expect(CredentialStore.parsePasswordLine(#"password: "ab"c d""#) == #"ab"c d"#)
    #expect(CredentialStore.parsePasswordLine(#"password: "cafe""#) == "cafe")
}

@Test func testParsePasswordLineNonASCIIHex() {
    let line = #"password: 0xED959CEAB8807077  "\355\225\234\352\270\200pw""#
    #expect(CredentialStore.parsePasswordLine(line) == "한글pw")
}

@Test func testAddPasswordCommandRejectsNewlines() {
    #expect(throws: CredentialError.self) {
        try CredentialStore.addPasswordCommand(service: "svc", account: "acct", value: "line1\nline2")
    }
}

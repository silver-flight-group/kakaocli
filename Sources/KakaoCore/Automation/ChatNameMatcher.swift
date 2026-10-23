import Foundation

/// Picks the one chat a user-supplied name refers to, or refuses when it can't tell.
///
/// Sending to the wrong chat can't be undone, so this never falls back to
/// "first in the list". Resolution order:
/// 1. Exact name matches, if any; otherwise case-insensitive substring matches.
/// 2. If exactly one candidate remains, use it.
/// 3. If several remain but exactly one is a 1:1 chat, use it — a person's name
///    (e.g. "강순미") also appears in group chats that list them as a member.
/// 4. Otherwise `.ambiguous`, listing the candidate names.
public enum ChatNameMatcher {
    public struct Candidate: Sendable, Equatable {
        public let name: String
        public let isGroup: Bool

        public init(name: String, isGroup: Bool) {
            self.name = name
            self.isGroup = isGroup
        }
    }

    public enum Pick: Equatable {
        case found(Int)
        case notFound
        case ambiguous([String])
    }

    public static func pick(_ query: String, from candidates: [Candidate]) -> Pick {
        let substring = candidates.indices.filter { candidates[$0].name.localizedCaseInsensitiveContains(query) }
        let exact = substring.filter { candidates[$0].name == query }
        let matches = exact.isEmpty ? substring : exact

        if matches.isEmpty { return .notFound }
        if matches.count == 1 { return .found(matches[0]) }
        let direct = matches.filter { !candidates[$0].isGroup }
        if direct.count == 1 { return .found(direct[0]) }
        return .ambiguous(matches.map { candidates[$0].name })
    }
}

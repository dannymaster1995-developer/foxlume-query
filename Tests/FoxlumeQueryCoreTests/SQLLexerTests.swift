import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct SQLLexerTests {
    func kinds(_ sql: String, _ family: SQLDialect.Family = .postgresql) -> [String] {
        SQLLexer.tokenize(sql, family: family).map { "\($0.kind):\($0.value)" }
    }

    @Test func splitsWordsPunctuationAndOperators() {
        #expect(kinds("SELECT o.id, count(*)::int FROM orders o WHERE a<>b") == [
            "word:SELECT", "word:o", "punctuation:.", "word:id", "punctuation:,", "word:count", "punctuation:(", "symbol:*",
            "punctuation:)", "symbol:::", "word:int", "word:FROM", "word:orders", "word:o", "word:WHERE", "word:a", "symbol:<>", "word:b",
        ])
    }

    @Test func stringsCommentsAndQuotedIdentifiers() {
        let tokens = SQLLexer.tokenize("SELECT 'it''s', \"Order \"\"x\"\"\" -- note\n/* block */ `t`", family: .postgresql)
        #expect(tokens.map(\.kind) == [.word, .string, .punctuation, .quotedIdentifier, .comment, .comment, .quotedIdentifier])
        #expect(tokens[3].value == "Order \"x\"")
        #expect(tokens[6].value == "t")
    }

    @Test func mysqlTreatsHashAsCommentAndDoubleQuotesAsStrings() {
        let tokens = SQLLexer.tokenize("SELECT \"a\\\"b\" # c\nFROM `my``table`", family: .mysql)
        #expect(tokens.map(\.kind) == [.word, .string, .comment, .word, .quotedIdentifier])
        #expect(tokens[4].value == "my`table")
    }

    @Test func unterminatedTokensRunToTheEnd() {
        let tokens = SQLLexer.tokenize("SELECT 'abc", family: .postgresql)
        #expect(tokens.last?.kind == .string)
        #expect(tokens.last?.isUnterminated == true)
        let quoted = SQLLexer.tokenize("SELECT * FROM \"ord", family: .postgresql)
        #expect(quoted.last?.kind == .quotedIdentifier && quoted.last?.value == "ord" && quoted.last?.isUnterminated == true)
    }

    @Test func dollarQuotingParametersAndNumbers() {
        #expect(kinds("SELECT $$a;b$$, $tag$x$tag$, $1, ?, :name, @v, 1.5e3, .5, 0xFF") == [
            "word:SELECT", "string:$$a;b$$", "punctuation:,", "string:$tag$x$tag$", "punctuation:,", "parameter:$1", "punctuation:,",
            "parameter:?", "punctuation:,", "parameter::name", "punctuation:,", "parameter:@v", "punctuation:,", "number:1.5e3",
            "punctuation:,", "number:.5", "punctuation:,", "number:0xFF",
        ])
    }

    @Test func rangesAreUTF16Offsets() {
        let text = "SELECT 'Zürich', naïve FROM t"
        let tokens = SQLLexer.tokenize(text, family: .postgresql)
        let ns = text as NSString
        for token in tokens {
            #expect(ns.substring(with: token.range) == token.text)
        }
        #expect(tokens[3].value == "naïve")
    }
}

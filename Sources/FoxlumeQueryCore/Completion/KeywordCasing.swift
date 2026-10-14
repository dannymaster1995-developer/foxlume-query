import Foundation

/// Applies the keyword-case setting to suggestions (spec 5.3). Pure and locale independent.
public enum KeywordCasing {
    /// Whether items should be uppercase for this prefix and policy.
    public static func usesUppercase(prefix: String, policy: KeywordCase) -> Bool {
        switch policy {
        case .upper: return true
        case .lower: return false
        case .matchTypedElseUpper: return typedCase(prefix) ?? true
        case .matchTypedElseLower: return typedCase(prefix) ?? false
        }
    }

    /// The case of the first cased character typed: true for upper, false for lower, nil when nothing is cased
    /// (empty, `_`, digits, scripts without case).
    static func typedCase(_ prefix: String) -> Bool? {
        for character in prefix {
            if character.isLowercase { return false }
            if character.isUppercase || character.isCased { return true }
        }
        return nil
    }

    /// Re-cases label and insert text of items that follow the setting; names and other fixed items are untouched.
    /// Multi-word phrases fold as one (`group b` gives `group by`). Highlights keep their ranges.
    public static func apply(items: [CompletionItem], prefix: String, policy: KeywordCase) -> [CompletionItem] {
        let upper = usesUppercase(prefix: prefix, policy: policy)
        return items.map { item in
            guard item.followsKeywordCase else { return item }
            var cased = item
            // Swift's case mapping uses the root locale, so `i` never becomes a dotted/dotless Turkish I.
            cased.label = upper ? item.label.uppercased() : item.label.lowercased()
            cased.insertText = upper ? item.insertText.uppercased() : item.insertText.lowercased()
            return cased
        }
    }
}

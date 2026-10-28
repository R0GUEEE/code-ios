import Foundation
import UIKit

/// Regex-based syntax colouring. Deliberately small: this is the native editor's
/// paint layer, not a language server. Rules run in order and later ones win, so
/// strings and comments override anything they overlap.
enum SyntaxHighlighter {
    struct Theme {
        let base: UIColor
        let keyword: UIColor
        let string: UIColor
        let comment: UIColor
        let number: UIColor
        let type: UIColor

        static let dark = Theme(
            base: UIColor(white: 0.92, alpha: 1),
            keyword: UIColor(red: 0.98, green: 0.55, blue: 0.72, alpha: 1),
            string: UIColor(red: 0.65, green: 0.85, blue: 0.55, alpha: 1),
            comment: UIColor(white: 0.48, alpha: 1),
            number: UIColor(red: 0.85, green: 0.75, blue: 0.5, alpha: 1),
            type: UIColor(red: 0.45, green: 0.78, blue: 0.95, alpha: 1)
        )

        static let light = Theme(
            base: UIColor(white: 0.1, alpha: 1),
            keyword: UIColor(red: 0.62, green: 0.1, blue: 0.45, alpha: 1),
            string: UIColor(red: 0.15, green: 0.45, blue: 0.15, alpha: 1),
            comment: UIColor(white: 0.55, alpha: 1),
            number: UIColor(red: 0.55, green: 0.3, blue: 0.05, alpha: 1),
            type: UIColor(red: 0.1, green: 0.35, blue: 0.6, alpha: 1)
        )
    }

    /// Past this size, colouring costs more than it is worth on a phone.
    private static let limit = 200_000

    static func highlight(_ text: String,
                          language: Language,
                          font: UIFont,
                          theme: Theme) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: theme.base]
        )
        guard text.utf16.count < limit, language != .plain else { return attributed }

        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)

        func paint(_ pattern: String, _ color: UIColor, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: text, options: [], range: full) {
                attributed.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        let spec = rules(for: language)
        for pattern in spec.keywords { paint(pattern, theme.keyword) }
        for pattern in spec.types { paint(pattern, theme.type) }
        paint(#"\b\d+(\.\d+)?\b"#, theme.number)
        for pattern in spec.strings { paint(pattern, theme.string, options: [.dotMatchesLineSeparators]) }
        for pattern in spec.comments { paint(pattern, theme.comment, options: [.dotMatchesLineSeparators]) }
        return attributed
    }

    private struct Rules {
        var keywords: [String] = []
        var types: [String] = []
        var strings: [String] = []
        var comments: [String] = []
    }

    private static func rules(for language: Language) -> Rules {
        switch language {
        case .swift:
            return Rules(
                keywords: [#"\b(func|let|var|if|else|guard|return|struct|class|enum|extension|protocol|import|init|self|nil|true|false|for|in|while|switch|case|default|try|catch|throw|throws|async|await|actor|some|any|public|private|internal|static|mutating|override|where|defer|typealias)\b"#],
                types: [#"\b[A-Z][A-Za-z0-9_]*\b"#],
                strings: [#""(?:[^"\\]|\\.)*""#],
                comments: [#"//[^\n]*"#, #"/\*[\s\S]*?\*/"#]
            )
        case .python:
            return Rules(
                keywords: [#"\b(def|class|if|elif|else|return|import|from|as|for|in|while|try|except|finally|with|lambda|yield|raise|pass|break|continue|and|or|not|is|None|True|False|self|async|await|global|nonlocal)\b"#],
                types: [#"\b[A-Z][A-Za-z0-9_]*\b"#],
                strings: [#"""(?:[^"\\]|\\.)*"""#, #"'(?:[^'\\]|\\.)*'"#],
                comments: [#"#[^\n]*"#]
            )
        case .javascript, .typescript:
            return Rules(
                keywords: [#"\b(const|let|var|function|return|if|else|for|while|class|extends|new|this|import|export|from|default|async|await|try|catch|finally|throw|typeof|instanceof|interface|type|enum|implements|public|private|readonly|null|undefined|true|false)\b"#],
                types: [#"\b[A-Z][A-Za-z0-9_]*\b"#],
                strings: [#""(?:[^"\\]|\\.)*""#, #"'(?:[^'\\]|\\.)*'"#, #"`(?:[^`\\]|\\.)*`"#],
                comments: [#"//[^\n]*"#, #"/\*[\s\S]*?\*/"#]
            )
        case .json:
            return Rules(
                keywords: [#""[^"]+"\s*:"#],
                types: [#"\b(true|false|null)\b"#],
                strings: [#""(?:[^"\\]|\\.)*""#],
                comments: [#"//[^\n]*"#]
            )
        case .markdown:
            return Rules(
                keywords: [#"^#{1,6}\s.*$"#, #"\*\*[^*]+\*\*"#],
                types: [#"`[^`\n]+`"#],
                strings: [#"\[[^\]]+\]\([^)]+\)"#],
                comments: [#"^>.*$"#]
            )
        case .html:
            return Rules(
                keywords: [#"</?[a-zA-Z][^>\s]*"#],
                types: [#"\b[a-zA-Z-]+="#],
                strings: [#""(?:[^"\\]|\\.)*""#],
                comments: [#"<!--[\s\S]*?-->"#]
            )
        case .css:
            return Rules(
                keywords: [#"[.#]?[a-zA-Z-]+\s*\{"#, #"\b(color|background|margin|padding|display|flex|font|border|position|width|height)\b"#],
                types: [#"#[0-9a-fA-F]{3,8}\b"#],
                strings: [#""(?:[^"\\]|\\.)*""#],
                comments: [#"/\*[\s\S]*?\*/"#]
            )
        case .shell:
            return Rules(
                keywords: [#"\b(if|then|else|fi|for|in|do|done|while|case|esac|function|export|local|echo|cd|return|exit)\b"#],
                types: [#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#],
                strings: [#""(?:[^"\\]|\\.)*""#, #"'[^']*'"#],
                comments: [#"(?m)^\s*#[^\n]*"#]
            )
        case .plain:
            return Rules()
        }
    }
}

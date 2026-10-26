import UIKit

/// A small Markdown renderer covering what chat replies use most: fenced code blocks,
/// headings, list items, quotes, **bold**, *italic* and `inline code`.
enum Markdown {
    static let bodyFont = UIFont.systemFont(ofSize: 16)
    static let codeFont: UIFont = {
        if #available(iOS 13.0, *) {
            return UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        }
        return UIFont(name: "Menlo-Regular", size: 14) ?? UIFont.systemFont(ofSize: 14)
    }()

    static func render(_ text: String, color: UIColor = Theme.text) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: color, .paragraphStyle: paragraph]

        let codeParagraph = NSMutableParagraphStyle()
        codeParagraph.lineSpacing = 2
        let codeAttrs: [NSAttributedString.Key: Any] = [
            .font: codeFont, .foregroundColor: color,
            .backgroundColor: Theme.codeBackground, .paragraphStyle: codeParagraph,
        ]

        var inCode = false
        var codeLines: [String] = []
        let lines = text.components(separatedBy: "\n")

        func appendNewlineIfNeeded() {
            if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: base)) }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    appendNewlineIfNeeded()
                    result.append(NSAttributedString(string: codeLines.joined(separator: "\n"), attributes: codeAttrs))
                    codeLines = []
                }
                inCode.toggle()
                continue
            }
            if inCode {
                codeLines.append(line)
                continue
            }

            appendNewlineIfNeeded()
            var content = line
            var attrs = base
            if let level = headingLevel(trimmed) {
                content = String(trimmed.dropFirst(level + 1))
                let size: CGFloat = level == 1 ? 21 : (level == 2 ? 19 : 17)
                attrs[.font] = UIFont.boldSystemFont(ofSize: size)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let indent = String(repeating: "  ", count: (line.count - line.drop(while: { $0 == " " }).count) / 2)
                content = indent + "• " + String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix("> ") {
                content = "┃ " + String(trimmed.dropFirst(2))
                attrs[.foregroundColor] = Theme.secondaryText
            } else if trimmed == "---" || trimmed == "***" {
                content = "────────────"
                attrs[.foregroundColor] = Theme.secondaryText
            }
            result.append(inline(content, attrs: attrs))
        }
        // Unterminated fence while streaming: still show the code.
        if inCode && !codeLines.isEmpty {
            appendNewlineIfNeeded()
            result.append(NSAttributedString(string: codeLines.joined(separator: "\n"), attributes: codeAttrs))
        }
        return result
    }

    private static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard level >= 1, level <= 6, line.count > level,
              line[line.index(line.startIndex, offsetBy: level)] == " " else { return nil }
        return level
    }

    private static func inline(_ text: String, attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseFont = attrs[.font] as? UIFont ?? bodyFont
        let chars = Array(text)
        var i = 0
        var plain = ""

        func flush() {
            if !plain.isEmpty {
                result.append(NSAttributedString(string: plain, attributes: attrs))
                plain = ""
            }
        }

        func find(_ marker: [Character], from start: Int) -> Int? {
            var j = start
            while j + marker.count <= chars.count {
                if Array(chars[j..<j + marker.count]) == marker { return j }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let ch = chars[i]
            if ch == "`", let end = find(["`"], from: i + 1), end > i + 1 {
                flush()
                var codeAttrs = attrs
                codeAttrs[.font] = codeFont
                codeAttrs[.backgroundColor] = Theme.codeBackground
                result.append(NSAttributedString(string: String(chars[i + 1..<end]), attributes: codeAttrs))
                i = end + 1
            } else if ch == "*", i + 1 < chars.count, chars[i + 1] == "*",
                      let end = find(["*", "*"], from: i + 2), end > i + 2 {
                flush()
                var boldAttrs = attrs
                boldAttrs[.font] = UIFont.boldSystemFont(ofSize: baseFont.pointSize)
                result.append(NSAttributedString(string: String(chars[i + 2..<end]), attributes: boldAttrs))
                i = end + 2
            } else if ch == "*", i + 1 < chars.count, chars[i + 1] != " ",
                      let end = find(["*"], from: i + 1), end > i + 1 {
                flush()
                var italicAttrs = attrs
                italicAttrs[.font] = UIFont.italicSystemFont(ofSize: baseFont.pointSize)
                result.append(NSAttributedString(string: String(chars[i + 1..<end]), attributes: italicAttrs))
                i = end + 1
            } else {
                plain.append(ch)
                i += 1
            }
        }
        flush()
        return result
    }
}

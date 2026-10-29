import AppKit
import Foundation

// Minimal block-aware Markdown renderer for AppKit text views.
//
// Foundation parses Markdown into an AttributedString with block "presentation intents"
// (headers, paragraphs, lists, code blocks), but AppKit ignores them: converting naively
// loses every paragraph break and sets no text color (black on a dark background).
// This walks the runs, groups them by their innermost block, and builds an NSAttributedString
// with paragraph breaks, heading sizes, list bullets/indents, code blocks, and adaptive colors.
//
// Not handled (yet): tables, block quotes, thematic breaks, images, multi-paragraph list items.

enum MarkdownRenderer {
    static func render(_ md: String, size: CGFloat = 13) -> NSAttributedString {
        var opts = AttributedString.MarkdownParsingOptions()
        opts.interpretedSyntax = .full
        guard let a = try? AttributedString(markdown: md, options: opts) else {
            return NSAttributedString(string: md, attributes: [.font: NSFont.systemFont(ofSize: size),
                                                               .foregroundColor: NSColor.labelColor])
        }

        let out = NSMutableAttributedString()
        var curID: Int?
        var blockStart = 0
        var style = NSMutableParagraphStyle()
        var header: Int?
        var isCode = false

        func close() {
            guard curID != nil else { return }
            if isCode, out.string.hasSuffix("\n") { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
            out.append(NSAttributedString(string: "\n", attributes: [.foregroundColor: NSColor.labelColor,
                                                                      .font: NSFont.systemFont(ofSize: size)]))
            out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: blockStart, length: out.length - blockStart))
        }

        for run in a.runs {
            let comps = run.presentationIntent?.components ?? []
            let id = comps.first?.identity
            if id != curID {
                close()
                curID = id
                blockStart = out.length
                style = NSMutableParagraphStyle()
                style.paragraphSpacing = 8
                header = nil
                isCode = false
                var listDepth = 0
                var ordinal: Int?
                var ordered = false
                for c in comps {
                    switch c.kind {
                    case .header(let level): header = level
                    case .codeBlock: isCode = true
                    case .listItem(let o): listDepth += 1; if ordinal == nil { ordinal = o }
                    case .orderedList: ordered = true
                    default: break
                    }
                }
                if header != nil { if blockStart > 0 { style.paragraphSpacingBefore = 10 } }
                if isCode { style.firstLineHeadIndent = 10; style.headIndent = 10; style.tailIndent = -10 }
                if listDepth > 0 {
                    let indent = 8 + 18 * CGFloat(listDepth - 1)
                    style.firstLineHeadIndent = indent
                    style.headIndent = indent + 16
                    style.paragraphSpacing = 3
                    let prefix = ordered ? "\(ordinal ?? 1).\u{00A0}" : "•\u{00A0}"
                    out.append(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: size),
                                                                                .foregroundColor: NSColor.secondaryLabelColor]))
                }
            }

            let text = String(a[run.range].characters)
            let inline = run.inlinePresentationIntent ?? []
            var font: NSFont
            if isCode || inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
            } else if let h = header {
                let bump: [CGFloat] = [11, 7, 4, 2, 1, 0]
                font = .systemFont(ofSize: size + bump[min(max(h, 1), 6) - 1], weight: .bold)
            } else {
                font = .systemFont(ofSize: size)
            }
            if inline.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if inline.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }

            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if isCode || inline.contains(.code) { attrs[.backgroundColor] = NSColor.secondaryLabelColor.withAlphaComponent(0.15) }
            if inline.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        close()
        return out
    }
}

import AppKit
import SwiftUI

struct AgentMarkdownView: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.sections(source), id: \.id) { section in
                switch section {
                case let .block(block):
                    blockView(block)
                case let .table(cells):
                    table(cells)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
                  case .allow = UntrustedURL(url.absoluteString).decision
            else { return .discarded }
            return .systemAction
        })
    }

    private struct Block: Identifiable {
        let id: Int
        let components: [PresentationIntent.IntentType]
        var text: AttributedString
    }

    private enum Section {
        case block(Block)
        case table([Block])

        var id: Int {
            switch self {
            case let .block(block): block.id
            case let .table(cells): cells[0].id
            }
        }
    }

    private static func sections(_ source: String) -> [Section] {
        var sections: [Section] = []
        var cells: [Block] = []
        var tableID: Int?
        for block in blocks(source) {
            let owner = block.components.first { if case .table = $0.kind { true } else { false } }?.identity
            if owner != tableID, !cells.isEmpty {
                sections.append(.table(cells))
                cells = []
            }
            if owner != nil {
                cells.append(block)
            } else {
                sections.append(.block(block))
            }
            tableID = owner
        }
        if !cells.isEmpty { sections.append(.table(cells)) }
        return sections
    }

    private static func blocks(_ source: String) -> [Block] {
        guard let content = try? AttributedString(markdown: source), !content.characters.isEmpty else {
            return [Block(id: 0, components: [], text: AttributedString(source))]
        }
        var blocks: [Block] = []
        for run in content.runs {
            let components = run.presentationIntent?.components ?? []
            let id = components.first?.identity ?? 0
            var text = AttributedString(content[run.range])
            text.presentationIntent = nil
            if run.inlinePresentationIntent?.contains(.code) == true {
                text.font = .system(.body, design: .monospaced)
            }
            if blocks.last?.id == id {
                blocks[blocks.count - 1].text.append(text)
            } else {
                blocks.append(Block(id: id, components: components, text: text))
            }
        }
        return blocks
    }

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block.components.first?.kind {
        case let .header(level):
            prose(block.text)
                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .accessibilityAddTraits(.isHeader)
        case let .codeBlock(languageHint):
            code(String(block.text.characters), language: languageHint)
        case .thematicBreak:
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
        default:
            paragraph(block)
        }
    }

    private func paragraph(_ block: Block) -> some View {
        let containers = block.components.dropFirst()
        let listItems = containers.compactMap { component -> Int? in
            if case let .listItem(number) = component.kind { return number }
            return nil
        }
        let isOrdered = containers.first(where: { component in
            switch component.kind {
            case .orderedList,
                 .unorderedList: true
            default: false
            }
        }).map { if case .orderedList = $0.kind { true } else { false } } ?? false
        let isQuote = containers.contains { if case .blockQuote = $0.kind { true } else { false } }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let number = listItems.first {
                Text(verbatim: isOrdered ? "\(number)." : "•")
                    .monospacedDigit()
                    .foregroundStyle(MactermTheme.fgMuted)
            }
            prose(block.text)
                .foregroundStyle(isQuote ? MactermTheme.fgMuted : MactermTheme.fg)
        }
        .padding(.leading, 12 * CGFloat(max(0, listItems.count - 1)) + (isQuote ? 8 : 0))
        .overlay(alignment: .leading) {
            if isQuote {
                Rectangle().fill(MactermTheme.border).frame(width: 2).accessibilityHidden(true)
            }
        }
    }

    private func prose(_ text: AttributedString) -> some View {
        Text(text)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func table(_ cells: [Block]) -> some View {
        let rows = Dictionary(grouping: cells) { $0.components.dropFirst().first?.identity ?? 0 }
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(rows.keys.sorted(), id: \.self) { id in
                    if let row = rows[id] {
                        let isHeader = row.first?.components.dropFirst().first?.kind == .tableHeaderRow
                        GridRow {
                            ForEach(row) { cell in
                                prose(cell.text)
                                    .fontWeight(isHeader ? .semibold : .regular)
                                    .fixedSize()
                            }
                        }
                        if isHeader {
                            Rectangle().fill(MactermTheme.border).frame(height: 1)
                                .gridCellUnsizedAxes(.horizontal)
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func code(_ text: String, language: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .accessibilityHidden(true)
                if let language, !language.isEmpty {
                    Text(verbatim: language).lineLimit(1)
                } else {
                    Text("Code")
                }
                Spacer()
                Button {
                    copyAgentText(text)
                } label: {
                    Label("Copy Code", systemImage: "document.on.document").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(Text("Copy Code"))
            }
            .font(.caption)
            .foregroundStyle(MactermTheme.fgMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            ScrollView(.horizontal) {
                Text(verbatim: text.hasSuffix("\n") ? String(text.dropLast()) : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
        }
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(MactermTheme.border).allowsHitTesting(false)
        }
    }
}

@MainActor
func copyAgentText(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

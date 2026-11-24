import AppKit
@testable import Macterm
import Testing

@MainActor
struct AgentComposerTests {
    private func makeInput(
        placeholder: String = "Write a message…"
    ) throws -> (window: NSWindow, input: AgentComposer.InputView) {
        let frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        let window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        let scroll = AgentComposer.InputView.scrollableTextView()
        scroll.frame = frame
        scroll.drawsBackground = false
        window.contentView = scroll

        let input = try #require(scroll.documentView as? AgentComposer.InputView)
        input.frame = frame
        input.drawsBackground = false
        input.font = NSFont.systemFont(ofSize: 13)
        input.textContainerInset = NSSize(width: 12, height: 8)
        input.textContainer?.lineFragmentPadding = 0
        input.placeholder = placeholder
        input.placeholderColor = .labelColor
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (window, input)
    }

    private func hasVisiblePixels(in view: NSView, rect: NSRect) throws -> Bool {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let scaleX = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
        let scaleY = CGFloat(rep.pixelsHigh) / max(1, view.bounds.height)
        let minX = max(0, Int(floor(rect.minX * scaleX)))
        let maxX = min(rep.pixelsWide - 1, Int(ceil(rect.maxX * scaleX)))
        let minY = max(0, Int(floor(rect.minY * scaleY)))
        let maxY = min(rep.pixelsHigh - 1, Int(ceil(rect.maxY * scaleY)))
        guard minX <= maxX, minY <= maxY else { return false }

        for y in minY ... maxY {
            for x in minX ... maxX {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    return true
                }
            }
        }
        return false
    }

    @Test
    func placeholderHidesDuringMarkedTextCompositionAndRestoresWhenCleared() throws {
        let (window, input) = try makeInput(placeholder: "MMMMMMMMMMMMMMMMMM")
        defer { _ = window }
        let trailingArea = NSRect(x: 80, y: 0, width: 140, height: 40)

        #expect(input.showsPlaceholder)
        #expect(try hasVisiblePixels(in: input, rect: trailingArea))

        input.setMarkedText(
            "s",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(input.hasMarkedText())
        #expect(!input.showsPlaceholder)
        #expect(try !hasVisiblePixels(in: input, rect: trailingArea))

        input.setMarkedText(
            "",
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(!input.hasMarkedText())
        #expect(input.string.isEmpty)
        #expect(input.showsPlaceholder)
        #expect(try hasVisiblePixels(in: input, rect: trailingArea))
    }

    @Test
    func placeholderStaysHiddenAfterCommitAndRestoresOnProgrammaticClear() throws {
        let (window, input) = try makeInput(placeholder: "MMMMMMMMMMMMMMMMMM")
        defer { _ = window }
        let trailingArea = NSRect(x: 80, y: 0, width: 140, height: 40)

        input.setMarkedText(
            "sdfds",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        input.insertText("水电费都是", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!input.hasMarkedText())
        #expect(input.string == "水电费都是")
        #expect(!input.showsPlaceholder)
        #expect(try !hasVisiblePixels(in: input, rect: trailingArea))

        input.string = ""
        #expect(input.showsPlaceholder)
        #expect(try hasVisiblePixels(in: input, rect: trailingArea))
    }

    @Test
    func emptyPlaceholderNeverShows() throws {
        let (window, input) = try makeInput(placeholder: "")
        defer { _ = window }
        #expect(!input.showsPlaceholder)
        #expect(try !hasVisiblePixels(in: input, rect: input.bounds))
    }
}

import AppKit
import CoreText
import Foundation
import Observation
import SwiftUI

/// Maximum horizontal width of the conversation column in the Agent GUI pane.
enum AgentContentWidth: String, CaseIterable, Identifiable, PreferenceValue {
    case compact
    case standard
    case wide
    case full

    var id: String { rawValue }

    var maxWidth: CGFloat? {
        switch self {
        case .compact: 580
        case .standard: 680
        case .wide: 900
        case .full: nil
        }
    }

    var displayName: String {
        switch self {
        case .compact: String(localized: "Compact", comment: "Agent GUI content width")
        case .standard: String(localized: "Standard", comment: "Agent GUI content width")
        case .wide: String(localized: "Wide", comment: "Agent GUI content width")
        case .full: String(localized: "Full width", comment: "Agent GUI content width")
        }
    }

    func resolvedWidth(for viewportWidth: CGFloat, horizontalInset: CGFloat = 32) -> CGFloat {
        let available = max(0, viewportWidth - horizontalInset)
        guard let maxWidth else { return available }
        return min(maxWidth, available)
    }
}

/// Immutable typography and layout snapshot rendered by the Agent GUI.
struct AgentAppearance: Equatable {
    static let defaultFontSize: Double = 13
    static let fontSizeRange: ClosedRange<Double> = 10 ... 24
    static let defaultLineSpacing: Double = 3
    static let lineSpacingRange: ClosedRange<Double> = 0 ... 12

    static let `default` = AgentAppearance(
        fontFamily: "",
        codeFontFamily: "",
        fontSize: defaultFontSize,
        lineSpacing: defaultLineSpacing,
        contentWidth: .standard
    )

    var fontFamily: String
    var codeFontFamily: String
    var fontSize: Double
    var lineSpacing: Double
    var contentWidth: AgentContentWidth

    var bodySize: CGFloat { CGFloat(fontSize) }
    var emptyTitleSize: CGFloat { (bodySize * 1.38).rounded() }
    var headingSize: CGFloat { (bodySize * 1.23).rounded() }
    var subheadingSize: CGFloat { (bodySize * 1.08).rounded() }
    var calloutSize: CGFloat { max(10, bodySize - 1) }
    var captionSize: CGFloat { max(9, bodySize - 2) }
    var codeBlockSize: CGFloat { max(10, bodySize - 1) }
    var captionCodeSize: CGFloat { max(9, bodySize - 2) }
    var lineSpacingPoints: CGFloat { CGFloat(lineSpacing) }

    /// Minimum height for the multiline composer so one line never clips at larger font sizes.
    var composerMinHeight: CGFloat {
        max(36, ceil(bodySize + 23))
    }

    func bodyNSFont(
        size: CGFloat? = nil,
        weight: NSFont.Weight = .regular,
        italic: Bool = false
    ) -> NSFont {
        let targetSize = size ?? bodySize
        let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if !family.isEmpty, let custom = Self.resolveCustomNSFont(
            family: family,
            size: targetSize,
            weight: weight,
            italic: italic
        ) {
            return custom
        }
        let system = NSFont.systemFont(ofSize: targetSize, weight: weight)
        guard italic else { return system }
        return NSFontManager.shared.convert(system, toHaveTrait: .italicFontMask)
    }

    func codeNSFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> NSFont {
        let targetSize = size ?? codeBlockSize
        let family = codeFontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if !family.isEmpty, let custom = Self.resolveCustomNSFont(
            family: family,
            size: targetSize,
            weight: weight,
            italic: false
        ) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: targetSize, weight: weight)
    }

    func bodyFont(
        size: CGFloat? = nil,
        weight: NSFont.Weight = .regular,
        italic: Bool = false
    ) -> Font {
        Font(bodyNSFont(size: size, weight: weight, italic: italic))
    }

    func codeFont(size: CGFloat? = nil, weight: NSFont.Weight = .regular) -> Font {
        Font(codeNSFont(size: size, weight: weight))
    }

    var emptyTitleFont: Font { bodyFont(size: emptyTitleSize, weight: .semibold) }
    var headlineFont: Font { bodyFont(size: subheadingSize, weight: .semibold) }

    func calloutFont(weight: NSFont.Weight = .regular) -> Font {
        bodyFont(size: calloutSize, weight: weight)
    }

    func captionFont(weight: NSFont.Weight = .regular) -> Font {
        bodyFont(size: captionSize, weight: weight)
    }

    private static func resolveCustomNSFont(
        family: String,
        size: CGFloat,
        weight: NSFont.Weight,
        italic: Bool
    ) -> NSFont? {
        var traits: NSFontTraitMask = []
        if weight == .bold || weight == .heavy || weight == .black {
            traits.insert(.boldFontMask)
        }
        if italic {
            traits.insert(.italicFontMask)
        }
        let manager = NSFontManager.shared
        let managerWeight = fontManagerWeight(for: weight)
        if let font = manager.font(withFamily: family, traits: traits, weight: managerWeight, size: size) {
            return font
        }
        if let base = manager.font(withFamily: family, traits: [], weight: 5, size: size) ?? NSFont(name: family, size: size) {
            return traits.isEmpty ? base : manager.convert(base, toHaveTrait: traits)
        }
        return nil
    }

    private static func fontManagerWeight(for weight: NSFont.Weight) -> Int {
        if weight >= .bold { return 9 }
        if weight >= .semibold { return 8 }
        if weight >= .medium { return 6 }
        return 5
    }
}

/// Observable UserDefaults-backed settings for Agent GUI appearance.
@MainActor @Observable
final class AgentAppearanceSettings {
    static let shared = AgentAppearanceSettings()

    enum Keys {
        static let fontFamily = PreferenceStorageKey("macterm.agent.ui.fontFamily", default: "")
        static let codeFontFamily = PreferenceStorageKey("macterm.agent.ui.codeFontFamily", default: "")
        static let fontSize = PreferenceStorageKey(
            "macterm.agent.ui.fontSize",
            default: AgentAppearance.defaultFontSize,
            normalize: clampFontSize
        )
        static let lineSpacing = PreferenceStorageKey(
            "macterm.agent.ui.lineSpacing",
            default: AgentAppearance.defaultLineSpacing,
            normalize: clampLineSpacing
        )
        static let contentWidth = PreferenceStorageKey(
            "macterm.agent.ui.contentWidth",
            default: AgentContentWidth.standard
        )
    }

    private let defaults: UserDefaults

    var fontFamily: String {
        didSet { Keys.fontFamily.write(fontFamily, to: defaults) }
    }

    var codeFontFamily: String {
        didSet { Keys.codeFontFamily.write(codeFontFamily, to: defaults) }
    }

    var fontSize: Double {
        didSet {
            let clamped = Self.clampFontSize(fontSize)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            Keys.fontSize.write(fontSize, to: defaults)
        }
    }

    var lineSpacing: Double {
        didSet {
            let clamped = Self.clampLineSpacing(lineSpacing)
            if clamped != lineSpacing {
                lineSpacing = clamped
                return
            }
            Keys.lineSpacing.write(lineSpacing, to: defaults)
        }
    }

    var contentWidth: AgentContentWidth {
        didSet { Keys.contentWidth.write(contentWidth, to: defaults) }
    }

    init(defaults: UserDefaults = Preferences.defaults) {
        self.defaults = defaults
        fontFamily = Keys.fontFamily.read(defaults)
        codeFontFamily = Keys.codeFontFamily.read(defaults)
        fontSize = Keys.fontSize.read(defaults)
        lineSpacing = Keys.lineSpacing.read(defaults)
        contentWidth = Keys.contentWidth.read(defaults)
    }

    var appearance: AgentAppearance {
        AgentAppearance(
            fontFamily: fontFamily,
            codeFontFamily: codeFontFamily,
            fontSize: fontSize,
            lineSpacing: lineSpacing,
            contentWidth: contentWidth
        )
    }

    var isDefault: Bool {
        appearance == .default
    }

    func resetToDefaults() {
        fontFamily = Keys.fontFamily.defaultValue
        codeFontFamily = Keys.codeFontFamily.defaultValue
        fontSize = Keys.fontSize.defaultValue
        lineSpacing = Keys.lineSpacing.defaultValue
        contentWidth = Keys.contentWidth.defaultValue
    }

    nonisolated static func clampFontSize(_ value: Double) -> Double {
        let clamped = min(max(value, AgentAppearance.fontSizeRange.lowerBound), AgentAppearance.fontSizeRange.upperBound)
        return clamped.rounded()
    }

    nonisolated static func clampLineSpacing(_ value: Double) -> Double {
        let clamped = min(max(value, AgentAppearance.lineSpacingRange.lowerBound), AgentAppearance.lineSpacingRange.upperBound)
        return clamped.rounded()
    }
}

/// Snapshot of installed macOS font families used by Agent GUI pickers.
struct AgentFontCatalog: Equatable {
    let allFamilies: [String]
    let monospacedFamilies: [String]
    let otherFamilies: [String]

    static let empty = AgentFontCatalog(allFamilies: [], monospacedFamilies: [], otherFamilies: [])

    @MainActor
    private static var cached: AgentFontCatalog?

    @MainActor
    static func loadCached() async -> AgentFontCatalog {
        if let cached { return cached }
        let loaded = await Task.detached(priority: .userInitiated) {
            Self.loadFromSystem()
        }.value
        cached = loaded
        return loaded
    }

    nonisolated static func loadFromSystem() -> AgentFontCatalog {
        let rawFamilies = (CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? [])
            .filter { !$0.isEmpty && !$0.hasPrefix(".") }
        let allSorted = Array(Set(rawFamilies)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }

        let monoTraits: [CFString: Any] = [
            kCTFontSymbolicTrait: CTFontSymbolicTraits.monoSpaceTrait.rawValue,
        ]
        let monoDescriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontTraitsAttribute: monoTraits,
        ] as CFDictionary)
        let matching = CTFontDescriptorCreateMatchingFontDescriptors(
            monoDescriptor,
            Set([kCTFontTraitsAttribute as String]) as CFSet
        ) as? [CTFontDescriptor] ?? []

        var monoSet = Set<String>()
        for descriptor in matching {
            if let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
               !family.isEmpty, !family.hasPrefix(".")
            {
                monoSet.insert(family)
            }
        }

        let monospaced = allSorted.filter { monoSet.contains($0) }
        let other = allSorted.filter { !monoSet.contains($0) }
        return AgentFontCatalog(allFamilies: allSorted, monospacedFamilies: monospaced, otherFamilies: other)
    }

    /// Returns all body font families, ensuring a saved family remains selectable even if uninstalled.
    func bodyFamilies(including selected: String) -> [String] {
        guard !selected.isEmpty, !allFamilies.contains(selected) else { return allFamilies }
        return [selected] + allFamilies
    }

    /// Returns monospaced and non-monospaced code font families, ensuring a saved family remains selectable.
    func codeFamilySections(including selected: String) -> (monospaced: [String], other: [String]) {
        guard !selected.isEmpty, !monospacedFamilies.contains(selected), !otherFamilies.contains(selected) else {
            return (monospacedFamilies, otherFamilies)
        }
        return ([selected] + monospacedFamilies, otherFamilies)
    }
}

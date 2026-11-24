import AppKit
import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentAppearanceTests {
    @Test
    func defaultsAndPersistenceRoundTrip() {
        let defaults = IsolatedDefaults.make()
        let settings = AgentAppearanceSettings(defaults: defaults)

        #expect(settings.isDefault)
        #expect(settings.appearance == .default)
        #expect(settings.fontFamily.isEmpty)
        #expect(settings.codeFontFamily.isEmpty)
        #expect(settings.fontSize == AgentAppearance.defaultFontSize)
        #expect(settings.lineSpacing == AgentAppearance.defaultLineSpacing)
        #expect(settings.contentWidth == .standard)

        settings.fontFamily = "Helvetica Neue"
        settings.codeFontFamily = "Menlo"
        settings.fontSize = 16
        settings.lineSpacing = 6
        settings.contentWidth = .wide
        #expect(!settings.isDefault)

        let reloaded = AgentAppearanceSettings(defaults: defaults)
        #expect(reloaded.fontFamily == "Helvetica Neue")
        #expect(reloaded.codeFontFamily == "Menlo")
        #expect(reloaded.fontSize == 16)
        #expect(reloaded.lineSpacing == 6)
        #expect(reloaded.contentWidth == .wide)

        reloaded.resetToDefaults()
        #expect(reloaded.isDefault)

        let afterReset = AgentAppearanceSettings(defaults: defaults)
        #expect(afterReset.appearance == .default)
    }

    @Test
    func outOfRangeValuesClampCleanly() {
        let defaults = IsolatedDefaults.make()
        defaults.set(99.0, forKey: AgentAppearanceSettings.Keys.fontSize.name)
        defaults.set(-4.0, forKey: AgentAppearanceSettings.Keys.lineSpacing.name)

        let settings = AgentAppearanceSettings(defaults: defaults)
        #expect(settings.fontSize == AgentAppearance.fontSizeRange.upperBound)
        #expect(settings.lineSpacing == AgentAppearance.lineSpacingRange.lowerBound)

        settings.fontSize = 4
        #expect(settings.fontSize == AgentAppearance.fontSizeRange.lowerBound)
        settings.lineSpacing = 30
        #expect(settings.lineSpacing == AgentAppearance.lineSpacingRange.upperBound)
    }

    @Test
    func contentWidthResolvesForViewport() {
        #expect(AgentContentWidth.compact.resolvedWidth(for: 1200) == 580)
        #expect(AgentContentWidth.standard.resolvedWidth(for: 1200) == 680)
        #expect(AgentContentWidth.wide.resolvedWidth(for: 1200) == 900)
        #expect(AgentContentWidth.full.resolvedWidth(for: 1200) == 1168)
        #expect(AgentContentWidth.wide.resolvedWidth(for: 500) == 468)
        #expect(AgentContentWidth.standard.resolvedWidth(for: 16) == 0)
    }

    @Test
    func fontResolutionHonorsSizeAndFallsBackWhenMissing() {
        let custom = AgentAppearance(
            fontFamily: "Helvetica",
            codeFontFamily: "Menlo",
            fontSize: 17,
            lineSpacing: 5,
            contentWidth: .standard
        )
        let bodyFont = custom.bodyNSFont()
        let codeFont = custom.codeNSFont()
        #expect(bodyFont.pointSize == 17)
        #expect(codeFont.pointSize == 16)

        let missing = AgentAppearance(
            fontFamily: "NonExistentFontFamilyXYZ123",
            codeFontFamily: "NonExistentMonoXYZ123",
            fontSize: 18,
            lineSpacing: 3,
            contentWidth: .standard
        )
        #expect(missing.bodyNSFont().pointSize == 18)
        #expect(missing.codeNSFont().pointSize == 17)
    }

    @Test
    func fontCatalogKeepsMissingSelectionValid() {
        let catalog = AgentFontCatalog(
            allFamilies: ["Helvetica", "Menlo"],
            monospacedFamilies: ["Menlo"],
            otherFamilies: ["Helvetica"]
        )
        #expect(catalog.bodyFamilies(including: "") == ["Helvetica", "Menlo"])
        #expect(catalog.bodyFamilies(including: "Helvetica") == ["Helvetica", "Menlo"])
        #expect(catalog.bodyFamilies(including: "Removed Font") == ["Removed Font", "Helvetica", "Menlo"])

        let existingCode = catalog.codeFamilySections(including: "Menlo")
        #expect(existingCode.monospaced == ["Menlo"])
        #expect(existingCode.other == ["Helvetica"])

        let missingCode = catalog.codeFamilySections(including: "Removed Mono")
        #expect(missingCode.monospaced == ["Removed Mono", "Menlo"])
        #expect(missingCode.other == ["Helvetica"])
    }
}

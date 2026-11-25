import CoreGraphics
@testable import Macterm
import Testing

@MainActor
struct AgentToolGroupLayoutTests {
    @Test
    func maxListHeightFallsBackWhenViewportHeightIsUnavailable() {
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: 0) == AgentToolGroupLayout.defaultMaxHeight)
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: -40) == AgentToolGroupLayout.defaultMaxHeight)
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: .nan) == AgentToolGroupLayout.defaultMaxHeight)
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: .infinity) == AgentToolGroupLayout.defaultMaxHeight)
    }

    @Test
    func maxListHeightScalesWithViewportAndClampsToBounds() {
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: 200) == AgentToolGroupLayout.minMaxHeight)
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: 601) == 300)
        #expect(AgentToolGroupLayout.maxListHeight(forViewportHeight: 1200) == AgentToolGroupLayout.maxMaxHeight)
    }

    @Test
    func scrollStateActivatesOnlyWhenContentExceedsMaxHeight() {
        #expect(!AgentToolGroupLayout.isScrollable(contentHeight: 0, maxHeight: 320))
        #expect(!AgentToolGroupLayout.isScrollable(contentHeight: 180, maxHeight: 320))
        #expect(!AgentToolGroupLayout.isScrollable(contentHeight: 320, maxHeight: 320))
        #expect(AgentToolGroupLayout.isScrollable(contentHeight: 320.2, maxHeight: 320))
        #expect(AgentToolGroupLayout.isScrollable(contentHeight: 900, maxHeight: 320))
    }

    @Test
    func resolvedListHeightHugsContentUntilCappedAtMaxHeight() {
        #expect(AgentToolGroupLayout.resolvedListHeight(contentHeight: 0, maxHeight: 320) == nil)
        #expect(AgentToolGroupLayout.resolvedListHeight(contentHeight: 124.2, maxHeight: 320) == 125)
        #expect(AgentToolGroupLayout.resolvedListHeight(contentHeight: 320, maxHeight: 320) == 320)
        #expect(AgentToolGroupLayout.resolvedListHeight(contentHeight: 980, maxHeight: 320) == 320)
    }
}

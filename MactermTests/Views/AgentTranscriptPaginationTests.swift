@testable import Macterm
import Testing

@MainActor
struct AgentTranscriptPaginationTests {
    private func makeIDs(_ count: Int, prefix: String = "row") -> [String] {
        (0 ..< count).map { "\(prefix)-\($0)" }
    }

    @Test
    func showsAllEntriesWhenCountWithinPageSize() {
        let pagination = AgentTranscriptPagination(pageSize: 30)
        let ids = makeIDs(12)

        #expect(pagination.visibleStartIndex(in: ids) == 0)
        #expect(pagination.hiddenCount(in: ids) == 0)
    }

    @Test
    func hidesOlderEntriesBeyondPageSizeByDefault() {
        let pagination = AgentTranscriptPagination(pageSize: 30)
        let ids = makeIDs(85)

        #expect(pagination.visibleStartIndex(in: ids) == 55)
        #expect(pagination.hiddenCount(in: ids) == 55)
    }

    @Test
    func loadMoreExpandsBackwardPageByPageUntilStart() {
        var pagination = AgentTranscriptPagination(pageSize: 30)
        let ids = makeIDs(85)

        pagination.loadMore(in: ids)
        #expect(pagination.visibleStartIndex(in: ids) == 25)
        #expect(pagination.hiddenCount(in: ids) == 25)
        #expect(pagination.anchorStartID == "row-25")

        pagination.loadMore(in: ids)
        #expect(pagination.visibleStartIndex(in: ids) == 0)
        #expect(pagination.hiddenCount(in: ids) == 0)
        #expect(pagination.anchorStartID == "row-0")

        // Loading more when already at the beginning keeps the anchor unchanged.
        pagination.loadMore(in: ids)
        #expect(pagination.visibleStartIndex(in: ids) == 0)
        #expect(pagination.anchorStartID == "row-0")
    }

    @Test
    func appendingNewEntriesPreservesExpandedTopAnchor() {
        var pagination = AgentTranscriptPagination(pageSize: 30)
        let initialIDs = makeIDs(85)

        pagination.loadMore(in: initialIDs)
        #expect(pagination.visibleStartIndex(in: initialIDs) == 25)

        let appendedIDs = makeIDs(95)
        #expect(pagination.visibleStartIndex(in: appendedIDs) == 25)
        #expect(pagination.hiddenCount(in: appendedIDs) == 25)
    }

    @Test
    func appendingNewEntriesWithoutExpansionKeepsTailWindowCapped() {
        let pagination = AgentTranscriptPagination(pageSize: 30)

        #expect(pagination.visibleStartIndex(in: makeIDs(30)) == 0)
        #expect(pagination.visibleStartIndex(in: makeIDs(31)) == 1)
        #expect(pagination.visibleStartIndex(in: makeIDs(120)) == 90)
    }

    @Test
    func missingAnchorFallsBackToDefaultTailWindow() {
        var pagination = AgentTranscriptPagination(pageSize: 30)
        pagination.loadMore(in: makeIDs(85, prefix: "old"))
        #expect(pagination.anchorStartID == "old-25")

        let replacedIDs = makeIDs(50, prefix: "new")
        #expect(pagination.visibleStartIndex(in: replacedIDs) == 20)
        #expect(pagination.hiddenCount(in: replacedIDs) == 20)
    }

    @Test
    func resetClearsExpandedAnchor() {
        var pagination = AgentTranscriptPagination(pageSize: 30)
        let ids = makeIDs(85)
        pagination.loadMore(in: ids)
        #expect(pagination.visibleStartIndex(in: ids) == 25)

        pagination.reset()
        #expect(pagination.anchorStartID == nil)
        #expect(pagination.visibleStartIndex(in: ids) == 55)
    }
}

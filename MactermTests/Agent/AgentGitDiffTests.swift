import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentGitDiffTests {
    // MARK: - Porcelain v2 -z parsing

    @Test
    func parses_porcelain_v2_branch_and_changes_with_nul_separators() {
        let records = [
            "# branch.oid 0123456789abcdef0123456789abcdef01234567",
            "# branch.head feature/git-diff",
            "# branch.upstream origin/feature/git-diff",
            "# branch.ab +2 -1",
            "1 M. N... 100644 100644 100644 aaa bbb Sources/My File.swift",
            "1 .M N... 100644 100644 100644 aaa bbb 中文目录/说明.md",
            "2 R. N... 100644 100644 100644 aaa bbb R100 Sources/New Name.swift",
            "Sources/Old Name.swift",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc Conflict.swift",
            "? Untracked/New File.txt",
            "",
        ].joined(separator: "\0")

        let parsed = AgentGitDiffParser.parsePorcelainV2Z(records)

        #expect(parsed.branch == "feature/git-diff")
        #expect(parsed.upstream == "origin/feature/git-diff")
        #expect(parsed.hasHEAD)
        #expect(parsed.ahead == 2)
        #expect(parsed.behind == 1)
        #expect(parsed.files.count == 5)

        #expect(parsed.files[0].path == "Sources/My File.swift")
        #expect(parsed.files[0].isStaged)
        #expect(!parsed.files[0].isUnstaged)
        #expect(parsed.files[0].kind == .modified)

        #expect(parsed.files[1].path == "中文目录/说明.md")
        #expect(!parsed.files[1].isStaged)
        #expect(parsed.files[1].isUnstaged)

        #expect(parsed.files[2].path == "Sources/New Name.swift")
        #expect(parsed.files[2].originalPath == "Sources/Old Name.swift")
        #expect(parsed.files[2].kind == .renamed)
        #expect(parsed.files[2].gitPathspecs == ["Sources/Old Name.swift", "Sources/New Name.swift"])

        #expect(parsed.files[3].path == "Conflict.swift")
        #expect(parsed.files[3].isConflicted)
        #expect(parsed.files[3].kind == .conflicted)

        #expect(parsed.files[4].path == "Untracked/New File.txt")
        #expect(parsed.files[4].isUntracked)
        #expect(parsed.files[4].kind == .untracked)
    }

    @Test
    func parses_initial_unborn_head_and_detached_head() {
        let initial = [
            "# branch.oid (initial)",
            "# branch.head main",
            "? README.md",
            "",
        ].joined(separator: "\0")
        let parsedInitial = AgentGitDiffParser.parsePorcelainV2Z(initial)
        #expect(!parsedInitial.hasHEAD)
        #expect(parsedInitial.branch == "main")
        #expect(parsedInitial.files.count == 1)

        let detached = [
            "# branch.oid abcdef1234567890",
            "# branch.head (detached)",
            "",
        ].joined(separator: "\0")
        let parsedDetached = AgentGitDiffParser.parsePorcelainV2Z(detached)
        #expect(parsedDetached.hasHEAD)
        #expect(parsedDetached.branch == nil)
        #expect(parsedDetached.detachedAt == "abcdef1")
    }

    // MARK: - Numstat & Unified Diff parsing

    @Test
    func parses_numstat_z_including_binary_and_renames() {
        let raw = [
            "12\t3\tSources/App.swift",
            "-\t-\tAssets/logo.png",
            "4\t2\t",
            "Old/Path.swift",
            "New/Path.swift",
            "",
        ].joined(separator: "\0")

        let stats = AgentGitDiffParser.parseNumstatZ(raw)

        #expect(stats["Sources/App.swift"] == .init(additions: 12, deletions: 3, isBinary: false))
        #expect(stats["Assets/logo.png"] == .init(additions: 0, deletions: 0, isBinary: true))
        #expect(stats["New/Path.swift"] == .init(additions: 4, deletions: 2, isBinary: false))
    }

    @Test
    func parses_unified_diff_line_numbers_and_counts() {
        let diffText = """
        diff --git a/Hello.swift b/Hello.swift
        index 1111111..2222222 100644
        --- a/Hello.swift
        +++ b/Hello.swift
        @@ -10,4 +10,5 @@ func greet()
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         print(a)
        """

        let parsed = AgentGitDiffParser.parseUnifiedDiff(diffText, path: "Hello.swift")

        #expect(!parsed.isBinary)
        #expect(!parsed.isTruncated)
        #expect(parsed.additions == 2)
        #expect(parsed.deletions == 1)
        #expect(parsed.lines.count == 6)

        #expect(parsed.lines[0].kind == .hunk)
        #expect(parsed.lines[1].kind == .context)
        #expect(parsed.lines[1].oldLineNumber == 10)
        #expect(parsed.lines[1].newLineNumber == 10)
        #expect(parsed.lines[2].kind == .deletion)
        #expect(parsed.lines[2].oldLineNumber == 11)
        #expect(parsed.lines[2].newLineNumber == nil)
        #expect(parsed.lines[3].kind == .addition)
        #expect(parsed.lines[3].oldLineNumber == nil)
        #expect(parsed.lines[3].newLineNumber == 11)
        #expect(parsed.lines[4].kind == .addition)
        #expect(parsed.lines[4].newLineNumber == 12)
        #expect(parsed.lines[5].kind == .context)
        #expect(parsed.lines[5].oldLineNumber == 12)
        #expect(parsed.lines[5].newLineNumber == 13)
    }

    @Test
    func parses_binary_unified_diff_and_untracked_binary() {
        let binaryUnified = """
        diff --git a/img.png b/img.png
        Binary files a/img.png and b/img.png differ
        """
        let parsed = AgentGitDiffParser.parseUnifiedDiff(binaryUnified, path: "img.png")
        #expect(parsed.isBinary)
        #expect(parsed.lines.isEmpty)

        let binaryData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])
        let untracked = AgentGitDiffParser.makeUntrackedDiff(data: binaryData, path: "img.png")
        #expect(untracked.isBinary)
        #expect(untracked.lines.isEmpty)
    }

    @Test
    func builds_untracked_text_diff_with_line_numbers() {
        let data = Data("line1\nline2\n".utf8)
        let diff = AgentGitDiffParser.makeUntrackedDiff(data: data, path: "notes.txt")
        #expect(!diff.isBinary)
        #expect(diff.additions == 2)
        #expect(diff.deletions == 0)
        #expect(diff.lines.count == 3)
        #expect(diff.lines[0].kind == .hunk)
        #expect(diff.lines[1].text == "+line1")
        #expect(diff.lines[1].newLineNumber == 1)
        #expect(diff.lines[2].text == "+line2")
        #expect(diff.lines[2].newLineNumber == 2)
    }

    // MARK: - Commit Message Generator

    @Test
    func sanitizes_model_commit_message_output() {
        let raw = "```text\nCommit message: \"Add lightweight Git diff sheet\"\n```"
        #expect(AgentGitCommitMessageGenerator.sanitizeGeneratedMessage(raw) == "Add lightweight Git diff sheet")
    }

    @Test
    func detects_preferred_commit_language_from_recent_history() {
        let chinese = AgentGitCommitMessageGenerator.preferredLanguage(
            recentSubjects: ["修复输入框问题", "新增 Git Diff 视图"],
            appLanguageCode: "en"
        )
        #expect(chinese == .simplifiedChinese)

        let english = AgentGitCommitMessageGenerator.preferredLanguage(
            recentSubjects: ["Fix composer bug", "Add tests"],
            appLanguageCode: "zh-Hans"
        )
        #expect(english == .english)

        let fallbackToApp = AgentGitCommitMessageGenerator.preferredLanguage(
            recentSubjects: [],
            appLanguageCode: "zh-Hans"
        )
        #expect(fallbackToApp == .simplifiedChinese)
    }

    @Test
    func generates_deterministic_fallback_messages() {
        let added = AgentGitFileChange(
            path: "Macterm/Agent/AgentGitDiff.swift",
            originalPath: nil,
            indexStatus: "?",
            workTreeStatus: "?",
            isUntracked: true,
            isConflicted: false,
            additions: 40
        )
        let modified = AgentGitFileChange(
            path: "Macterm/Agent/AgentSettings.swift",
            originalPath: nil,
            indexStatus: ".",
            workTreeStatus: "M",
            isUntracked: false,
            isConflicted: false,
            additions: 3,
            deletions: 1
        )

        let singleZh = AgentGitCommitMessageGenerator.fallbackMessage(
            files: [added],
            diffs: [:],
            language: .simplifiedChinese
        )
        #expect(singleZh == "新增 AgentGitDiff.swift")

        let multiEn = AgentGitCommitMessageGenerator.fallbackMessage(
            files: [added, modified],
            diffs: [:],
            language: .english
        )
        #expect(multiEn.hasPrefix("Update 2 files in Agent\n\n"))
        #expect(multiEn.contains("- Add Macterm/Agent/AgentGitDiff.swift"))
        #expect(multiEn.contains("- Modify Macterm/Agent/AgentSettings.swift"))
    }

    // MARK: - End-to-End Git Service against temporary repositories

    @Test
    func selective_commit_preserves_unchecked_staged_files_and_supports_push_pull() async throws {
        guard let git = AgentGitService.resolveGitExecutable() else {
            return
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-git-diff-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let remoteURL = tempRoot.appendingPathComponent("remote.git", isDirectory: true)
        let localURL = tempRoot.appendingPathComponent("local", isDirectory: true)
        let peerURL = tempRoot.appendingPathComponent("peer", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localURL, withIntermediateDirectories: true)

        try await runShellGit(git, in: remoteURL.path, ["init", "--bare", "-b", "main"])
        try await runShellGit(git, in: localURL.path, ["init", "-b", "main"])
        try await runShellGit(git, in: localURL.path, ["config", "user.name", "Test User"])
        try await runShellGit(git, in: localURL.path, ["config", "user.email", "test@example.com"])
        try await runShellGit(git, in: localURL.path, ["remote", "add", "origin", remoteURL.path])

        // Initial commit on unborn HEAD with selective file (leave extra.txt unchecked).
        let subDir = localURL.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
        try "a1\n".write(to: localURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "b1\n".write(to: localURL.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try "extra\n".write(to: subDir.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)

        let initialSnap = try await AgentGitService.loadSnapshot(directory: subDir.path, gitExecutable: git)
        #expect(!initialSnap.hasHEAD)
        #expect(initialSnap.files.count == 3)

        _ = try await AgentGitService.commit(
            repositoryRoot: initialSnap.repositoryRoot,
            snapshot: initialSnap,
            selectedPaths: ["a.txt", "b.txt"],
            message: "初始化仓库",
            gitExecutable: git
        )

        // First push sets upstream automatically (-u origin HEAD).
        let afterInitial = try await AgentGitService.loadSnapshot(directory: localURL.path, gitExecutable: git)
        #expect(afterInitial.hasHEAD)
        #expect(afterInitial.upstream == nil)
        #expect(afterInitial.files.map(\.path) == ["sub/extra.txt"])

        _ = try await AgentGitService.push(
            repositoryRoot: afterInitial.repositoryRoot,
            snapshot: afterInitial,
            gitExecutable: git
        )

        // Stage a.txt, modify b.txt unstaged, keep sub/extra.txt untracked.
        // Commit ONLY b.txt and sub/extra.txt -> a.txt MUST remain staged and uncommitted!
        try "a2\n".write(to: localURL.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await runShellGit(git, in: localURL.path, ["add", "a.txt"])
        try "b2\n".write(to: localURL.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let snapBeforeSelective = try await AgentGitService.loadSnapshot(directory: localURL.path, gitExecutable: git)
        #expect(snapBeforeSelective.upstream == "origin/main")
        #expect(snapBeforeSelective.files.count == 3)

        let bFile = try #require(snapBeforeSelective.files.first { $0.path == "b.txt" })
        let bDiff = await AgentGitService.loadFileDiff(
            repositoryRoot: snapBeforeSelective.repositoryRoot,
            file: bFile,
            hasHEAD: true,
            gitExecutable: git
        )
        #expect(bDiff.additions == 1)
        #expect(bDiff.deletions == 1)

        _ = try await AgentGitService.commit(
            repositoryRoot: snapBeforeSelective.repositoryRoot,
            snapshot: snapBeforeSelective,
            selectedPaths: ["b.txt", "sub/extra.txt"],
            message: "仅提交 b 与 extra",
            gitExecutable: git
        )

        let snapAfterSelective = try await AgentGitService.loadSnapshot(directory: localURL.path, gitExecutable: git)
        #expect(snapAfterSelective.files.count == 1)
        #expect(snapAfterSelective.files[0].path == "a.txt")
        #expect(snapAfterSelective.files[0].isStaged)
        #expect(snapAfterSelective.ahead == 1)

        // Push second commit.
        _ = try await AgentGitService.push(
            repositoryRoot: snapAfterSelective.repositoryRoot,
            snapshot: snapAfterSelective,
            gitExecutable: git
        )

        // Create a remote commit from a peer clone, then pull from local.
        try await runShellGit(git, in: tempRoot.path, ["clone", remoteURL.path, peerURL.path])
        try await runShellGit(git, in: peerURL.path, ["config", "user.name", "Peer User"])
        try await runShellGit(git, in: peerURL.path, ["config", "user.email", "peer@example.com"])
        try "from peer\n".write(to: peerURL.appendingPathComponent("peer.txt"), atomically: true, encoding: .utf8)
        try await runShellGit(git, in: peerURL.path, ["add", "peer.txt"])
        try await runShellGit(git, in: peerURL.path, ["commit", "-m", "peer commit"])
        try await runShellGit(git, in: peerURL.path, ["push"])

        _ = try await AgentGitService.pull(repositoryRoot: localURL.path, gitExecutable: git)
        let pulledContent = try String(contentsOf: localURL.appendingPathComponent("peer.txt"), encoding: .utf8)
        #expect(pulledContent == "from peer\n")
    }

    private func runShellGit(_ git: String, in directory: String, _ args: [String]) async throws {
        let outcome = await ProcessRunner.run(
            git,
            ["-C", directory] + args,
            environment: ProcessInfo.processInfo.environment,
            timeout: .seconds(10)
        )
        let result = try #require(outcome)
        #expect(result.status == 0, "git \(args.joined(separator: " ")) failed: \(result.stderr)")
    }
}

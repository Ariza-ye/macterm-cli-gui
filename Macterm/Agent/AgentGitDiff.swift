import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AgentGitDiff")

/// One changed path reported by `git status` in the Agent Git Diff sheet.
struct AgentGitFileChange: Equatable, Identifiable {
    enum ChangeKind: String, Equatable {
        case added
        case modified
        case deleted
        case renamed
        case copied
        case untracked
        case conflicted
    }

    let path: String
    let originalPath: String?
    let indexStatus: Character
    let workTreeStatus: Character
    let isUntracked: Bool
    let isConflicted: Bool
    var additions = 0
    var deletions = 0
    var isBinary = false

    var id: String { path }

    var isStaged: Bool {
        !isUntracked && !isConflicted && indexStatus != "."
    }

    var isUnstaged: Bool {
        isUntracked || isConflicted || workTreeStatus != "."
    }

    var kind: ChangeKind {
        if isConflicted { return .conflicted }
        if isUntracked { return .untracked }
        if indexStatus == "R" || workTreeStatus == "R" { return .renamed }
        if indexStatus == "C" || workTreeStatus == "C" { return .copied }
        if indexStatus == "D" || workTreeStatus == "D" { return .deleted }
        if indexStatus == "A" || workTreeStatus == "A" { return .added }
        return .modified
    }

    var shortStatusCode: String {
        switch kind {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .conflicted: "U"
        }
    }

    var fileName: String {
        (path as NSString).lastPathComponent
    }

    var directoryPath: String? {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty || dir == "." ? nil : dir
    }

    /// All repo-relative pathspecs affected by this entry (includes the old path for renames).
    var gitPathspecs: [String] {
        if let originalPath, originalPath != path {
            return [originalPath, path]
        }
        return [path]
    }
}

/// Snapshot of a repository's branch, tracking state, and changed files.
struct AgentGitSnapshot: Equatable {
    let repositoryRoot: String
    let branch: String?
    let detachedAt: String?
    let upstream: String?
    let hasHEAD: Bool
    let ahead: Int
    let behind: Int
    let files: [AgentGitFileChange]

    var displayBranch: String {
        if let branch, !branch.isEmpty { return branch }
        if let detachedAt, !detachedAt.isEmpty { return detachedAt }
        return "HEAD"
    }

    var totalAdditions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    var totalDeletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }
}

/// One parsed line of a unified diff for display in the diff viewer.
struct AgentGitDiffLine: Equatable, Identifiable {
    enum Kind: Equatable {
        case header
        case hunk
        case context
        case addition
        case deletion
        case note
    }

    let id: Int
    let kind: Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let text: String
}

/// Parsed diff content for a single file.
struct AgentGitFileDiff: Equatable {
    let path: String
    let lines: [AgentGitDiffLine]
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isTruncated: Bool
    let rawText: String
}

/// Errors surfaced by `AgentGitService`.
enum AgentGitError: LocalizedError, Equatable {
    case gitUnavailable
    case notARepository
    case noFilesSelected
    case emptyCommitMessage
    case noRemoteConfigured
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .gitUnavailable:
            String(localized: "Git is not installed on this Mac.")
        case .notARepository:
            String(localized: "The current directory is not a Git repository.")
        case .noFilesSelected:
            String(localized: "Select at least one file to commit.")
        case .emptyCommitMessage:
            String(localized: "Enter a commit message before committing.")
        case .noRemoteConfigured:
            String(localized: "No Git remote is configured for this repository.")
        case let .commandFailed(message):
            message
        }
    }
}

/// Pure parsers for Git porcelain status, numstat, and unified diffs.
enum AgentGitDiffParser {
    struct ParsedStatus: Equatable {
        var branch: String?
        var detachedAt: String?
        var upstream: String?
        var hasHEAD = true
        var ahead = 0
        var behind = 0
        var files: [AgentGitFileChange] = []
    }

    struct NumstatEntry: Equatable {
        let additions: Int
        let deletions: Int
        let isBinary: Bool
    }

    static let defaultMaxRenderedLines = 2500
    static let defaultMaxUntrackedBytes = 262_144

    /// Parses `git status --porcelain=v2 --branch -z -uall`.
    static func parsePorcelainV2Z(_ text: String) -> ParsedStatus {
        var status = ParsedStatus()
        let records = text.unicodeScalars
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }

            if record.hasPrefix("# ") {
                parseHeader(record.dropFirst(2), into: &status)
                continue
            }

            switch record.first {
            case "1":
                let fields = record.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                status.files.append(AgentGitFileChange(
                    path: String(fields[8]),
                    originalPath: nil,
                    indexStatus: xy[0],
                    workTreeStatus: xy[1],
                    isUntracked: false,
                    isConflicted: false
                ))

            case "2":
                let fields = record.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let origPath: String? = if index < records.count {
                    records[index]
                } else {
                    nil
                }
                if origPath != nil { index += 1 }
                guard fields.count == 10, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                status.files.append(AgentGitFileChange(
                    path: String(fields[9]),
                    originalPath: origPath,
                    indexStatus: xy[0],
                    workTreeStatus: xy[1],
                    isUntracked: false,
                    isConflicted: false
                ))

            case "u":
                let fields = record.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                guard fields.count == 11, fields[1].count == 2 else { continue }
                let xy = Array(fields[1])
                status.files.append(AgentGitFileChange(
                    path: String(fields[10]),
                    originalPath: nil,
                    indexStatus: xy[0],
                    workTreeStatus: xy[1],
                    isUntracked: false,
                    isConflicted: true
                ))

            case "?":
                guard record.count >= 3 else { continue }
                status.files.append(AgentGitFileChange(
                    path: String(record.dropFirst(2)),
                    originalPath: nil,
                    indexStatus: "?",
                    workTreeStatus: "?",
                    isUntracked: true,
                    isConflicted: false
                ))

            default:
                continue
            }
        }
        return status
    }

    private static func parseHeader(_ header: Substring, into status: inout ParsedStatus) {
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return }
        let value = String(parts[1])
        switch parts[0] {
        case "branch.oid":
            if value == "(initial)" {
                status.hasHEAD = false
                status.detachedAt = nil
            } else {
                status.hasHEAD = true
                status.detachedAt = String(value.prefix(7))
            }
        case "branch.head":
            status.branch = value == "(detached)" ? nil : value
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    /// Parses `git diff --numstat -z`.
    /// Normal entries are `<added>\t<deleted>\t<path>\0`.
    /// Renamed entries are `<added>\t<deleted>\t\0<oldPath>\0<newPath>\0`.
    static func parseNumstatZ(_ text: String) -> [String: NumstatEntry] {
        var result: [String: NumstatEntry] = [:]
        let records = text.unicodeScalars
            .split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard !record.isEmpty else { continue }
            let columns = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            let isBinary = columns[0] == "-" && columns[1] == "-"
            let additions = Int(columns[0]) ?? 0
            let deletions = Int(columns[1]) ?? 0
            let path: String
            if columns[2].isEmpty {
                // Rename entry: next two NUL-terminated records are oldPath and newPath.
                guard index + 1 < records.count else { break }
                path = records[index + 1]
                index += 2
            } else {
                path = String(columns[2])
            }
            guard !path.isEmpty else { continue }
            result[path] = NumstatEntry(additions: additions, deletions: deletions, isBinary: isBinary)
        }
        return result
    }

    /// Parses unified diff output into line-numbered display lines.
    static func parseUnifiedDiff(
        _ text: String,
        path: String,
        maxLines: Int = defaultMaxRenderedLines
    ) -> AgentGitFileDiff {
        let rawLines = splitLinesPreservingCRLF(text)
        var lines: [AgentGitDiffLine] = []
        var additions = 0
        var deletions = 0
        var isBinary = false
        var isTruncated = false
        var oldLine: Int?
        var newLine: Int?
        var inHunk = false

        for rawLine in rawLines {
            if !inHunk, rawLine.hasPrefix("Binary files ") || rawLine.hasPrefix("GIT binary patch") {
                isBinary = true
            }

            if rawLine.hasPrefix("@@ ") {
                inHunk = true
                if let range = parseHunkHeader(rawLine) {
                    oldLine = range.oldStart
                    newLine = range.newStart
                }
                if lines.count < maxLines {
                    lines.append(AgentGitDiffLine(
                        id: lines.count,
                        kind: .hunk,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        text: rawLine
                    ))
                } else {
                    isTruncated = true
                }
                continue
            }

            if !inHunk {
                // Skip redundant preamble lines so the diff stays concise and readable.
                if rawLine.hasPrefix("diff --git ")
                    || rawLine.hasPrefix("index ")
                    || rawLine.hasPrefix("--- ")
                    || rawLine.hasPrefix("+++ ")
                {
                    continue
                }
                if !rawLine.isEmpty, lines.count < maxLines {
                    lines.append(AgentGitDiffLine(
                        id: lines.count,
                        kind: .header,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        text: rawLine
                    ))
                }
                continue
            }

            if rawLine.hasPrefix("+") {
                additions += 1
                let currentNew = newLine
                if let value = newLine { newLine = value + 1 }
                if lines.count < maxLines {
                    lines.append(AgentGitDiffLine(
                        id: lines.count,
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: currentNew,
                        text: rawLine
                    ))
                } else {
                    isTruncated = true
                }
            } else if rawLine.hasPrefix("-") {
                deletions += 1
                let currentOld = oldLine
                if let value = oldLine { oldLine = value + 1 }
                if lines.count < maxLines {
                    lines.append(AgentGitDiffLine(
                        id: lines.count,
                        kind: .deletion,
                        oldLineNumber: currentOld,
                        newLineNumber: nil,
                        text: rawLine
                    ))
                } else {
                    isTruncated = true
                }
            } else if rawLine.hasPrefix("\\ ") {
                if lines.count < maxLines {
                    lines.append(AgentGitDiffLine(
                        id: lines.count,
                        kind: .note,
                        oldLineNumber: nil,
                        newLineNumber: nil,
                        text: rawLine
                    ))
                } else {
                    isTruncated = true
                }
            } else {
                let currentOld = oldLine
                let currentNew = newLine
                if let value = oldLine { oldLine = value + 1 }
                if let value = newLine { newLine = value + 1 }
                if lines.count < maxLines {
                    lines.append(AgentGitDiffLine(
                        id: lines.count,
                        kind: .context,
                        oldLineNumber: currentOld,
                        newLineNumber: currentNew,
                        text: rawLine
                    ))
                } else {
                    isTruncated = true
                }
            }
        }

        return AgentGitFileDiff(
            path: path,
            lines: isBinary ? [] : lines,
            additions: additions,
            deletions: deletions,
            isBinary: isBinary,
            isTruncated: isTruncated,
            rawText: text
        )
    }

    /// Builds a unified-style addition diff from an untracked file's raw bytes.
    static func makeUntrackedDiff(
        data: Data,
        path: String,
        maxBytes: Int = defaultMaxUntrackedBytes,
        maxLines: Int = defaultMaxRenderedLines
    ) -> AgentGitFileDiff {
        if isLikelyBinary(data) {
            return AgentGitFileDiff(
                path: path,
                lines: [],
                additions: 0,
                deletions: 0,
                isBinary: true,
                isTruncated: false,
                rawText: ""
            )
        }

        let byteTruncated = data.count > maxBytes
        let slice = byteTruncated ? data.prefix(maxBytes) : data
        let content = String(decoding: slice, as: UTF8.self)
        let rawLines = splitLinesPreservingCRLF(content)
        let totalLines = rawLines.count
        let visibleLines = rawLines.prefix(maxLines)
        var lines: [AgentGitDiffLine] = []
        lines.reserveCapacity(visibleLines.count + 1)
        if !visibleLines.isEmpty {
            lines.append(AgentGitDiffLine(
                id: 0,
                kind: .hunk,
                oldLineNumber: nil,
                newLineNumber: nil,
                text: "@@ -0,0 +1,\(totalLines) @@"
            ))
        }
        for (offset, line) in visibleLines.enumerated() {
            lines.append(AgentGitDiffLine(
                id: lines.count,
                kind: .addition,
                oldLineNumber: nil,
                newLineNumber: offset + 1,
                text: "+\(line)"
            ))
        }
        let rawText = lines.map(\.text).joined(separator: "\n")
        return AgentGitFileDiff(
            path: path,
            lines: lines,
            additions: totalLines,
            deletions: 0,
            isBinary: false,
            isTruncated: byteTruncated || totalLines > maxLines,
            rawText: rawText
        )
    }

    static func isLikelyBinary(_ data: Data) -> Bool {
        let probeLength = min(data.count, 8192)
        return data.prefix(probeLength).contains(0)
    }

    private static func splitLinesPreservingCRLF(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { scalars -> String in
                var sub = Substring(scalars)
                if sub.unicodeScalars.last == "\r" {
                    sub = Substring(sub.unicodeScalars.dropLast())
                }
                return String(sub)
            }
        if lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func parseHunkHeader(_ line: String) -> (oldStart: Int, newStart: Int)? {
        // Format: @@ -oldStart[,oldCount] +newStart[,newCount] @@ ...
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "@@" else { return nil }
        guard parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        let oldToken = parts[1].dropFirst().split(separator: ",").first
        let newToken = parts[2].dropFirst().split(separator: ",").first
        guard let oldToken, let newToken, let oldStart = Int(oldToken), let newStart = Int(newToken) else {
            return nil
        }
        return (oldStart, newStart)
    }
}

/// Generates concise commit messages for the selected files, using Apple's on-device
/// model when available and falling back to a deterministic local summary otherwise.
enum AgentGitCommitMessageGenerator {
    enum CommitLanguage: Equatable {
        case english
        case simplifiedChinese
        case korean
    }

    static let maxDiffDigestCharacters = 5000
    static let maxResponseTokens = 160

    static func preferredLanguage(
        recentSubjects: [String],
        appLanguageCode: String? = Bundle.main.preferredLocalizations.first
    ) -> CommitLanguage {
        let nonEmpty = recentSubjects
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !nonEmpty.isEmpty {
            let chineseCount = nonEmpty.filter(containsCJK).count
            if chineseCount * 2 >= nonEmpty.count { return .simplifiedChinese }
            let koreanCount = nonEmpty.filter(containsHangul).count
            if koreanCount * 2 >= nonEmpty.count { return .korean }
            return .english
        }
        if let code = appLanguageCode?.lowercased() {
            if code.hasPrefix("zh") { return .simplifiedChinese }
            if code.hasPrefix("ko") { return .korean }
        }
        return .english
    }

    static func instructions(for language: CommitLanguage) -> String {
        let languageRule = switch language {
        case .simplifiedChinese:
            "Write the commit message in Simplified Chinese."
        case .korean:
            "Write the commit message in Korean."
        case .english:
            "Write the commit message in English."
        }
        return """
        You write clear, concise Git commit messages from a list of changed files and their diffs.
        \(languageRule)
        Output ONLY the commit message text with no quotes, no markdown fences, and no explanation.
        Keep the first line under 60 characters and summarize the actual intent of the changes.
        If multiple distinct changes are included, you may add a blank line followed by up to 3 short bullet points.
        """
    }

    static func buildPrompt(
        files: [AgentGitFileChange],
        diffs: [String: AgentGitFileDiff],
        branch: String?,
        recentSubjects: [String]
    ) -> String {
        var sections: [String] = []
        if let branch, !branch.isEmpty {
            sections.append("Branch: \(branch)")
        }
        if !recentSubjects.isEmpty {
            let list = recentSubjects.prefix(5).map { "- \($0)" }.joined(separator: "\n")
            sections.append("Recent commits:\n\(list)")
        }
        let fileList = files.map { file -> String in
            let stats = file.isBinary ? "binary" : "+\(file.additions)/-\(file.deletions)"
            if let orig = file.originalPath {
                return "- [\(file.shortStatusCode)] \(orig) -> \(file.path) (\(stats))"
            }
            return "- [\(file.shortStatusCode)] \(file.path) (\(stats))"
        }.joined(separator: "\n")
        sections.append("Selected files (\(files.count)):\n\(fileList)")

        var remaining = maxDiffDigestCharacters
        var diffBlocks: [String] = []
        for file in files where remaining > 120 {
            guard let diff = diffs[file.path], !diff.isBinary, !diff.lines.isEmpty else { continue }
            var snippet = "File: \(file.path)\n"
            for line in diff.lines {
                if line.kind == .header { continue }
                let next = line.text + "\n"
                if snippet.count + next.count > remaining {
                    break
                }
                snippet.append(next)
            }
            remaining -= snippet.count
            diffBlocks.append(snippet.trimmingCharacters(in: .newlines))
        }
        if !diffBlocks.isEmpty {
            sections.append("Diff excerpts:\n" + diffBlocks.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Removes code fences, surrounding quotes, and boilerplate prefixes from model output.
    static func sanitizeGeneratedMessage(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let stripped = lines.dropFirst().reversed().drop(while: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }).reversed()
            text = stripped.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let prefixes = ["Commit message:", "commit message:", "提交信息：", "提交信息:", "커밋 메시지:"]
        for prefix in prefixes where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.count >= 2,
           (text.hasPrefix("\"") && text.hasSuffix("\""))
           || (text.hasPrefix("'") && text.hasSuffix("'"))
        {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Deterministic commit message generator used when the on-device model is unavailable.
    static func fallbackMessage(
        files: [AgentGitFileChange],
        diffs: [String: AgentGitFileDiff],
        language: CommitLanguage
    ) -> String {
        guard !files.isEmpty else { return "" }

        let allAdded = files.allSatisfy { $0.kind == .added || $0.kind == .untracked }
        let allDeleted = files.allSatisfy { $0.kind == .deleted }
        let allRenamed = files.allSatisfy { $0.kind == .renamed }

        let subject: String
        if files.count == 1, let file = files.first {
            let target = file.fileName
            switch language {
            case .simplifiedChinese:
                if allAdded {
                    subject = "新增 \(target)"
                } else if allDeleted {
                    subject = "删除 \(target)"
                } else if let original = file.originalPath {
                    let oldName = (original as NSString).lastPathComponent
                    subject = "将 \(oldName) 重命名为 \(target)"
                } else {
                    subject = "更新 \(target)"
                }
            case .korean:
                if allAdded {
                    subject = "\(target) 추가"
                } else if allDeleted {
                    subject = "\(target) 삭제"
                } else if let original = file.originalPath {
                    let oldName = (original as NSString).lastPathComponent
                    subject = "\(oldName)을(를) \(target)(으)로 이름 변경"
                } else {
                    subject = "\(target) 수정"
                }
            case .english:
                if allAdded {
                    subject = "Add \(target)"
                } else if allDeleted {
                    subject = "Remove \(target)"
                } else if let original = file.originalPath {
                    let oldName = (original as NSString).lastPathComponent
                    subject = "Rename \(oldName) to \(target)"
                } else {
                    subject = "Update \(target)"
                }
            }
        } else {
            let scope = sharedScope(for: files)
            switch language {
            case .simplifiedChinese:
                let verb = allAdded ? "新增" : (allDeleted ? "删除" : (allRenamed ? "重命名" : "更新"))
                if let scope {
                    subject = "\(verb) \(scope) 中的 \(files.count) 个文件"
                } else if files.count <= 2 {
                    subject = "\(verb) \(files.map(\.fileName).joined(separator: "、"))"
                } else {
                    subject = "\(verb) \(files[0].fileName) 等 \(files.count) 个文件"
                }
            case .korean:
                let verb = allAdded ? "추가" : (allDeleted ? "삭제" : (allRenamed ? "이름 변경" : "수정"))
                if let scope {
                    subject = "\(scope)의 파일 \(files.count)개 \(verb)"
                } else if files.count <= 2 {
                    subject = "\(files.map(\.fileName).joined(separator: ", ")) \(verb)"
                } else {
                    subject = "\(files[0].fileName) 외 \(files.count - 1)개 파일 \(verb)"
                }
            case .english:
                let verb = allAdded ? "Add" : (allDeleted ? "Remove" : (allRenamed ? "Rename" : "Update"))
                if let scope {
                    subject = "\(verb) \(files.count) files in \(scope)"
                } else if files.count <= 2 {
                    subject = "\(verb) \(files.map(\.fileName).joined(separator: " and "))"
                } else {
                    subject = "\(verb) \(files[0].fileName) and \(files.count - 1) more files"
                }
            }
        }

        guard files.count > 1 else {
            if let file = files.first, let symbol = firstChangedSymbol(in: diffs[file.path]) {
                switch language {
                case .simplifiedChinese: return "\(subject)（\(symbol)）"
                case .korean: return "\(subject) (\(symbol))"
                case .english: return "\(subject) (\(symbol))"
                }
            }
            return subject
        }

        let maxBullets = 6
        let bullets = files.prefix(maxBullets).map { file -> String in
            let verb = switch language {
            case .simplifiedChinese:
                switch file.kind {
                case .added,
                     .untracked: "新增"
                case .deleted: "删除"
                case .renamed: "重命名"
                case .copied: "复制"
                case .modified,
                     .conflicted: "修改"
                }
            case .korean:
                switch file.kind {
                case .added,
                     .untracked: "추가"
                case .deleted: "삭제"
                case .renamed: "이름 변경"
                case .copied: "복사"
                case .modified,
                     .conflicted: "수정"
                }
            case .english:
                switch file.kind {
                case .added,
                     .untracked: "Add"
                case .deleted: "Delete"
                case .renamed: "Rename"
                case .copied: "Copy"
                case .modified,
                     .conflicted: "Modify"
                }
            }
            return "- \(verb) \(file.path)"
        }
        return ([subject, ""] + bullets).joined(separator: "\n")
    }

    @MainActor
    static func generate(
        files: [AgentGitFileChange],
        diffs: [String: AgentGitFileDiff],
        branch: String?,
        recentSubjects: [String],
        onPartial: @MainActor (String) -> Void
    ) async -> String {
        let language = preferredLanguage(recentSubjects: recentSubjects)
        if OnDeviceModel.availability == .available {
            let prompt = buildPrompt(files: files, diffs: diffs, branch: branch, recentSubjects: recentSubjects)
            let stream = OnDeviceModel.stream(
                instructions: instructions(for: language),
                prompt: prompt,
                maximumResponseTokens: maxResponseTokens
            )
            var latest = ""
            do {
                for try await partial in stream {
                    let cleaned = sanitizeGeneratedMessage(partial)
                    if !cleaned.isEmpty {
                        latest = cleaned
                        onPartial(cleaned)
                    }
                }
                if !latest.isEmpty {
                    return latest
                }
            } catch is CancellationError {
                return latest
            } catch {
                logger.info("on-device commit message fallback: \(EnglishErrorText.describe(error), privacy: .public)")
            }
        }
        let fallback = fallbackMessage(files: files, diffs: diffs, language: language)
        onPartial(fallback)
        return fallback
    }

    private static func sharedScope(for files: [AgentGitFileChange]) -> String? {
        let directories = files.compactMap(\.directoryPath)
        guard directories.count == files.count else { return nil }
        let splitPaths = directories.map { $0.split(separator: "/").map(String.init) }
        guard var common = splitPaths.first else { return nil }
        for components in splitPaths.dropFirst() {
            let count = zip(common, components).prefix { $0 == $1 }.count
            common = Array(common.prefix(count))
            if common.isEmpty { return nil }
        }
        return common.last
    }

    private static func firstChangedSymbol(in diff: AgentGitFileDiff?) -> String? {
        guard let diff, !diff.isBinary else { return nil }
        for line in diff.lines where line.kind == .hunk {
            // Standard `@@ -a,b +c,d @@ func foo(...)` context label emitted by git diff.
            let components = line.text.components(separatedBy: "@@")
            if components.count >= 3 {
                let context = components[2].trimmingCharacters(in: .whitespaces)
                if !context.isEmpty, context.count <= 36 {
                    return context
                }
            }
        }
        return nil
    }

    private static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00 ... 0x9FFF).contains(scalar.value)
                || (0x3400 ... 0x4DBF).contains(scalar.value)
        }
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xAC00 ... 0xD7A3).contains(scalar.value)
        }
    }
}

/// Stateless Git command runner for the Agent Git Diff sheet.
enum AgentGitService {
    static let readTimeout: Duration = .seconds(8)
    static let writeTimeout: Duration = .seconds(20)
    static let networkTimeout: Duration = .seconds(60)

    static func resolveGitExecutable() -> String? {
        ProjectGit.resolvedExecutable
    }

    static func loadSnapshot(directory: String, gitExecutable: String? = nil) async throws -> AgentGitSnapshot {
        guard let git = gitExecutable ?? resolveGitExecutable() else {
            throw AgentGitError.gitUnavailable
        }
        let topLevelOutcome = await runGit(
            git,
            in: directory,
            args: ["rev-parse", "--show-toplevel"],
            readOnly: true,
            timeout: readTimeout
        )
        guard let topLevelOutcome, topLevelOutcome.status == 0 else {
            throw AgentGitError.notARepository
        }
        let repoRoot = topLevelOutcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoRoot.isEmpty else {
            throw AgentGitError.notARepository
        }

        let statusOutcome = await runGit(
            git,
            in: repoRoot,
            args: ["status", "--porcelain=v2", "--branch", "-z", "-uall"],
            readOnly: true,
            timeout: readTimeout
        )
        guard let statusOutcome, statusOutcome.status == 0 else {
            throw AgentGitError.commandFailed(errorMessage(from: statusOutcome))
        }

        var parsed = AgentGitDiffParser.parsePorcelainV2Z(statusOutcome.stdout)

        let numstatArgs = parsed.hasHEAD
            ? ["diff", "HEAD", "--numstat", "-z"]
            : ["diff", "--cached", "--numstat", "-z"]
        let numstatOutcome = await runGit(git, in: repoRoot, args: numstatArgs, readOnly: true, timeout: readTimeout)
        let numstats = numstatOutcome.flatMap { $0.status == 0 ? AgentGitDiffParser.parseNumstatZ($0.stdout) : nil } ?? [:]

        for index in parsed.files.indices {
            let path = parsed.files[index].path
            if let stat = numstats[path] {
                parsed.files[index].additions = stat.additions
                parsed.files[index].deletions = stat.deletions
                parsed.files[index].isBinary = stat.isBinary
            } else if parsed.files[index].isUntracked {
                let fileURL = URL(fileURLWithPath: repoRoot).appendingPathComponent(path)
                if let stat = untrackedFileStat(at: fileURL) {
                    parsed.files[index].additions = stat.additions
                    parsed.files[index].isBinary = stat.isBinary
                }
            }
        }

        return AgentGitSnapshot(
            repositoryRoot: repoRoot,
            branch: parsed.branch,
            detachedAt: parsed.detachedAt,
            upstream: parsed.upstream,
            hasHEAD: parsed.hasHEAD,
            ahead: parsed.ahead,
            behind: parsed.behind,
            files: parsed.files
        )
    }

    static func loadFileDiff(
        repositoryRoot: String,
        file: AgentGitFileChange,
        hasHEAD: Bool,
        gitExecutable: String? = nil
    ) async -> AgentGitFileDiff {
        if file.isUntracked {
            let fileURL = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(file.path)
            if let data = readFilePrefix(at: fileURL, maxBytes: AgentGitDiffParser.defaultMaxUntrackedBytes + 1) {
                return AgentGitDiffParser.makeUntrackedDiff(data: data, path: file.path)
            }
            return AgentGitFileDiff(
                path: file.path,
                lines: [],
                additions: 0,
                deletions: 0,
                isBinary: false,
                isTruncated: false,
                rawText: ""
            )
        }

        guard let git = gitExecutable ?? resolveGitExecutable() else {
            return AgentGitFileDiff(
                path: file.path,
                lines: [],
                additions: 0,
                deletions: 0,
                isBinary: false,
                isTruncated: false,
                rawText: ""
            )
        }

        var args = hasHEAD ? ["diff", "HEAD"] : ["diff", "--cached"]
        args += ["--no-color", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/", "--"]
        args += file.gitPathspecs

        let outcome = await runGit(git, in: repositoryRoot, args: args, readOnly: true, timeout: readTimeout)
        if let outcome, outcome.status == 0, !outcome.stdout.isEmpty {
            return AgentGitDiffParser.parseUnifiedDiff(outcome.stdout, path: file.path)
        }

        // Fallback when a newly staged file on an unborn branch also has worktree edits or empty diff.
        if !hasHEAD {
            let fileURL = URL(fileURLWithPath: repositoryRoot).appendingPathComponent(file.path)
            if let data = readFilePrefix(at: fileURL, maxBytes: AgentGitDiffParser.defaultMaxUntrackedBytes + 1) {
                return AgentGitDiffParser.makeUntrackedDiff(data: data, path: file.path)
            }
        }

        return AgentGitFileDiff(
            path: file.path,
            lines: [],
            additions: file.additions,
            deletions: file.deletions,
            isBinary: file.isBinary,
            isTruncated: false,
            rawText: ""
        )
    }

    static func recentCommitSubjects(
        repositoryRoot: String,
        limit: Int = 5,
        gitExecutable: String? = nil
    ) async -> [String] {
        guard let git = gitExecutable ?? resolveGitExecutable() else { return [] }
        let outcome = await runGit(
            git,
            in: repositoryRoot,
            args: ["log", "-\(limit)", "--format=%s"],
            readOnly: true,
            timeout: readTimeout
        )
        guard let outcome, outcome.status == 0 else { return [] }
        return outcome.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Commits only the checked files without accidentally including unchecked staged changes.
    static func commit(
        repositoryRoot: String,
        snapshot: AgentGitSnapshot,
        selectedPaths: Set<String>,
        message: String,
        gitExecutable: String? = nil
    ) async throws -> String {
        guard let git = gitExecutable ?? resolveGitExecutable() else {
            throw AgentGitError.gitUnavailable
        }
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else {
            throw AgentGitError.emptyCommitMessage
        }
        let selectedFiles = snapshot.files.filter { selectedPaths.contains($0.path) }
        guard !selectedFiles.isEmpty else {
            throw AgentGitError.noFilesSelected
        }

        let selectedPathspecs = uniqueOrderedPathspecs(for: selectedFiles)
        let uncheckedStaged = snapshot.files.filter { !selectedPaths.contains($0.path) && $0.isStaged }

        if uncheckedStaged.isEmpty {
            let addOutcome = await runGit(
                git,
                in: repositoryRoot,
                args: ["add", "-A", "--"] + selectedPathspecs,
                readOnly: false,
                timeout: writeTimeout
            )
            guard let addOutcome, addOutcome.status == 0 else {
                throw AgentGitError.commandFailed(errorMessage(from: addOutcome))
            }
            let commitOutcome = await runGit(
                git,
                in: repositoryRoot,
                args: ["commit", "-F", "-"],
                readOnly: false,
                stdinText: trimmedMessage + "\n",
                timeout: writeTimeout
            )
            guard let commitOutcome, commitOutcome.status == 0 else {
                throw AgentGitError.commandFailed(errorMessage(from: commitOutcome))
            }
            return firstNonEmptyLine(of: commitOutcome.stdout) ?? String(localized: "Committed changes.")
        }

        if snapshot.hasHEAD {
            // Preserve unchecked staged entries by using `git commit --only -- <selectedPathspecs>`.
            // Untracked selected files need intent-to-add (`git add -N`) first so `--only` accepts them.
            let selectedUntracked = selectedFiles.filter(\.isUntracked).map(\.path)
            if !selectedUntracked.isEmpty {
                let intentOutcome = await runGit(
                    git,
                    in: repositoryRoot,
                    args: ["add", "-N", "--"] + selectedUntracked,
                    readOnly: false,
                    timeout: writeTimeout
                )
                guard let intentOutcome, intentOutcome.status == 0 else {
                    throw AgentGitError.commandFailed(errorMessage(from: intentOutcome))
                }
            }
            let commitOutcome = await runGit(
                git,
                in: repositoryRoot,
                args: ["commit", "--only", "-F", "-", "--"] + selectedPathspecs,
                readOnly: false,
                stdinText: trimmedMessage + "\n",
                timeout: writeTimeout
            )
            guard let commitOutcome, commitOutcome.status == 0 else {
                if !selectedUntracked.isEmpty {
                    _ = await runGit(
                        git,
                        in: repositoryRoot,
                        args: ["reset", "-q", "--"] + selectedUntracked,
                        readOnly: false,
                        timeout: writeTimeout
                    )
                }
                throw AgentGitError.commandFailed(errorMessage(from: commitOutcome))
            }
            return firstNonEmptyLine(of: commitOutcome.stdout) ?? String(localized: "Committed changes.")
        }

        // Unborn HEAD with unchecked staged files: unstage unchecked files from the empty index,
        // stage only the selected files, and commit.
        let uncheckedPathspecs = uniqueOrderedPathspecs(for: uncheckedStaged)
        let unstageOutcome = await runGit(
            git,
            in: repositoryRoot,
            args: ["rm", "--cached", "-q", "--"] + uncheckedPathspecs,
            readOnly: false,
            timeout: writeTimeout
        )
        guard let unstageOutcome, unstageOutcome.status == 0 else {
            throw AgentGitError.commandFailed(errorMessage(from: unstageOutcome))
        }
        let addOutcome = await runGit(
            git,
            in: repositoryRoot,
            args: ["add", "-A", "--"] + selectedPathspecs,
            readOnly: false,
            timeout: writeTimeout
        )
        guard let addOutcome, addOutcome.status == 0 else {
            throw AgentGitError.commandFailed(errorMessage(from: addOutcome))
        }
        let commitOutcome = await runGit(
            git,
            in: repositoryRoot,
            args: ["commit", "-F", "-"],
            readOnly: false,
            stdinText: trimmedMessage + "\n",
            timeout: writeTimeout
        )
        guard let commitOutcome, commitOutcome.status == 0 else {
            throw AgentGitError.commandFailed(errorMessage(from: commitOutcome))
        }
        return firstNonEmptyLine(of: commitOutcome.stdout) ?? String(localized: "Committed changes.")
    }

    static func push(
        repositoryRoot: String,
        snapshot: AgentGitSnapshot,
        gitExecutable: String? = nil
    ) async throws -> String {
        guard let git = gitExecutable ?? resolveGitExecutable() else {
            throw AgentGitError.gitUnavailable
        }
        let args: [String]
        if snapshot.upstream != nil {
            args = ["push"]
        } else {
            let remote = try await defaultRemoteName(git: git, repositoryRoot: repositoryRoot)
            args = ["push", "-u", remote, "HEAD"]
        }
        let outcome = await runGit(git, in: repositoryRoot, args: args, readOnly: false, timeout: networkTimeout)
        guard let outcome, outcome.status == 0 else {
            throw AgentGitError.commandFailed(errorMessage(from: outcome))
        }
        return firstNonEmptyLine(of: outcome.stdout)
            ?? firstNonEmptyLine(of: outcome.stderr)
            ?? String(localized: "Pushed to remote.")
    }

    static func pull(
        repositoryRoot: String,
        gitExecutable: String? = nil
    ) async throws -> String {
        guard let git = gitExecutable ?? resolveGitExecutable() else {
            throw AgentGitError.gitUnavailable
        }
        let outcome = await runGit(git, in: repositoryRoot, args: ["pull"], readOnly: false, timeout: networkTimeout)
        guard let outcome, outcome.status == 0 else {
            throw AgentGitError.commandFailed(errorMessage(from: outcome))
        }
        return firstNonEmptyLine(of: outcome.stdout)
            ?? firstNonEmptyLine(of: outcome.stderr)
            ?? String(localized: "Pulled from remote.")
    }

    // MARK: - Helpers

    private static func defaultRemoteName(git: String, repositoryRoot: String) async throws -> String {
        let outcome = await runGit(git, in: repositoryRoot, args: ["remote"], readOnly: true, timeout: readTimeout)
        guard let outcome, outcome.status == 0 else {
            throw AgentGitError.noRemoteConfigured
        }
        let remotes = outcome.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if remotes.contains("origin") { return "origin" }
        if let first = remotes.first { return first }
        throw AgentGitError.noRemoteConfigured
    }

    private static func uniqueOrderedPathspecs(for files: [AgentGitFileChange]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for file in files {
            for spec in file.gitPathspecs where seen.insert(spec).inserted {
                result.append(spec)
            }
        }
        return result
    }

    private static func untrackedFileStat(at url: URL) -> (additions: Int, isBinary: Bool)? {
        guard let data = readFilePrefix(at: url, maxBytes: AgentGitDiffParser.defaultMaxUntrackedBytes) else {
            return nil
        }
        if AgentGitDiffParser.isLikelyBinary(data) {
            return (0, true)
        }
        if data.isEmpty {
            return (0, false)
        }
        let newlineCount = data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        let endsWithNewline = data.last == 0x0A
        return (endsWithNewline ? newlineCount : newlineCount + 1, false)
    }

    private static func readFilePrefix(at url: URL, maxBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: maxBytes)
    }

    private static func runGit(
        _ git: String,
        in directory: String,
        args: [String],
        readOnly: Bool,
        stdinText: String? = nil,
        timeout: Duration
    ) async -> ProcessRunner.Outcome? {
        var environment = ProcessInfo.processInfo.environment
        if readOnly {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let fullArgs = ["-C", directory] + ProjectGit.gitOptions + args

        var inputPipe: Pipe?
        var inputHandle: FileHandle?
        if let stdinText {
            let pipe = Pipe()
            let data = Data(stdinText.utf8)
            try? pipe.fileHandleForWriting.write(contentsOf: data)
            try? pipe.fileHandleForWriting.close()
            inputPipe = pipe
            inputHandle = pipe.fileHandleForReading
        }
        defer {
            try? inputPipe?.fileHandleForReading.close()
        }
        return await ProcessRunner.run(
            git,
            fullArgs,
            environment: environment,
            input: inputHandle,
            timeout: timeout
        )
    }

    private static func errorMessage(from outcome: ProcessRunner.Outcome?) -> String {
        guard let outcome else {
            return String(localized: "Git command failed to start or timed out.")
        }
        let stderr = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty {
            return stderr
        }
        let stdout = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stdout.isEmpty {
            return stdout
        }
        return String(localized: "Git command exited with status \(outcome.status).")
    }

    private static func firstNonEmptyLine(of text: String) -> String? {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

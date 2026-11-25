import AppKit
import Observation
import SwiftUI

/// View model for the lightweight Git Diff sheet launched from `AgentPaneView`.
@MainActor
@Observable
final class AgentGitDiffState {
    enum FeedbackKind: Equatable {
        case success
        case error
    }

    struct Feedback: Equatable {
        let kind: FeedbackKind
        let message: String
    }

    enum RunningAction: Equatable {
        case refreshing
        case generatingMessage
        case committing
        case pushing
        case pulling
    }

    let workingDirectory: String?

    private(set) var snapshot: AgentGitSnapshot?
    private(set) var loadError: String?
    private(set) var runningAction: RunningAction?
    private(set) var feedback: Feedback?
    private(set) var diffsByPath: [String: AgentGitFileDiff] = [:]
    private(set) var loadingDiffPath: String?

    var checkedPaths: Set<String> = []
    var selectedPath: String?
    var commitMessage = ""

    @ObservationIgnored private var hasInitializedSelection = false
    @ObservationIgnored private var activeDiffTask: Task<Void, Never>?
    @ObservationIgnored private var activeGenerateTask: Task<Void, Never>?

    init(workingDirectory: String?) {
        self.workingDirectory = workingDirectory
    }

    var files: [AgentGitFileChange] {
        snapshot?.files ?? []
    }

    var selectedFile: AgentGitFileChange? {
        guard let selectedPath else { return nil }
        return files.first { $0.path == selectedPath }
    }

    var selectedDiff: AgentGitFileDiff? {
        guard let selectedPath else { return nil }
        return diffsByPath[selectedPath]
    }

    var checkedCount: Int {
        files.count { checkedPaths.contains($0.path) }
    }

    var allChecked: Bool {
        !files.isEmpty && checkedCount == files.count
    }

    var isBusy: Bool {
        runningAction != nil
    }

    var canGenerateCommitMessage: Bool {
        snapshot != nil && checkedCount > 0 && runningAction == nil
    }

    var canCommit: Bool {
        snapshot != nil
            && checkedCount > 0
            && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && runningAction == nil
    }

    var canPush: Bool {
        snapshot != nil && runningAction == nil
    }

    var canPull: Bool {
        snapshot != nil && runningAction == nil
    }

    func dismissFeedback() {
        feedback = nil
    }

    func toggleFileChecked(_ path: String) {
        if checkedPaths.contains(path) {
            checkedPaths.remove(path)
        } else {
            checkedPaths.insert(path)
        }
    }

    func toggleSelectAll() {
        if allChecked {
            checkedPaths.removeAll()
        } else {
            checkedPaths = Set(files.map(\.path))
        }
    }

    func selectFile(_ path: String) {
        selectedPath = path
        loadDiffIfNeeded(for: path)
    }

    func refresh(preserveFeedback: Bool = false) async {
        guard let workingDirectory, !workingDirectory.isEmpty else {
            snapshot = nil
            loadError = AgentGitError.notARepository.localizedDescription
            return
        }
        activeDiffTask?.cancel()
        runningAction = .refreshing
        if !preserveFeedback {
            feedback = nil
        }
        defer {
            if runningAction == .refreshing { runningAction = nil }
        }

        do {
            let previousPaths = Set(files.map(\.path))
            let newSnapshot = try await AgentGitService.loadSnapshot(directory: workingDirectory)
            snapshot = newSnapshot
            loadError = nil
            diffsByPath.removeAll()

            let currentPaths = Set(newSnapshot.files.map(\.path))
            if !hasInitializedSelection {
                checkedPaths = currentPaths
                hasInitializedSelection = true
            } else {
                // Keep existing user choices for surviving paths and auto-check newly appeared files.
                let newPaths = currentPaths.subtracting(previousPaths)
                checkedPaths = checkedPaths.intersection(currentPaths).union(newPaths)
            }

            if let selectedPath, currentPaths.contains(selectedPath) {
                loadDiffIfNeeded(for: selectedPath)
            } else if let first = newSnapshot.files.first {
                selectedPath = first.path
                loadDiffIfNeeded(for: first.path)
            } else {
                selectedPath = nil
            }
        } catch {
            snapshot = nil
            diffsByPath.removeAll()
            selectedPath = nil
            loadError = error.localizedDescription
        }
    }

    func generateCommitMessage() {
        guard let snapshot, canGenerateCommitMessage else { return }
        let selectedFiles = snapshot.files.filter { checkedPaths.contains($0.path) }
        guard !selectedFiles.isEmpty else { return }

        activeGenerateTask?.cancel()
        runningAction = .generatingMessage
        feedback = nil

        activeGenerateTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if runningAction == .generatingMessage { runningAction = nil }
            }
            var gatheredDiffs = diffsByPath
            for file in selectedFiles.prefix(8) where gatheredDiffs[file.path] == nil {
                guard !Task.isCancelled else { return }
                let diff = await AgentGitService.loadFileDiff(
                    repositoryRoot: snapshot.repositoryRoot,
                    file: file,
                    hasHEAD: snapshot.hasHEAD
                )
                gatheredDiffs[file.path] = diff
                diffsByPath[file.path] = diff
            }
            let recentSubjects = await AgentGitService.recentCommitSubjects(repositoryRoot: snapshot.repositoryRoot)
            guard !Task.isCancelled else { return }
            let generated = await AgentGitCommitMessageGenerator.generate(
                files: selectedFiles,
                diffs: gatheredDiffs,
                branch: snapshot.branch,
                recentSubjects: recentSubjects,
                onPartial: { [weak self] partial in
                    self?.commitMessage = partial
                }
            )
            if !Task.isCancelled, !generated.isEmpty {
                commitMessage = generated
            }
        }
    }

    func commit() async {
        guard let snapshot, canCommit else { return }
        runningAction = .committing
        feedback = nil
        do {
            let summary = try await AgentGitService.commit(
                repositoryRoot: snapshot.repositoryRoot,
                snapshot: snapshot,
                selectedPaths: checkedPaths,
                message: commitMessage
            )
            commitMessage = ""
            feedback = Feedback(kind: .success, message: summary)
            runningAction = nil
            await refresh(preserveFeedback: true)
        } catch {
            feedback = Feedback(kind: .error, message: error.localizedDescription)
            runningAction = nil
        }
    }

    func push() async {
        guard let snapshot, canPush else { return }
        runningAction = .pushing
        feedback = nil
        do {
            let summary = try await AgentGitService.push(
                repositoryRoot: snapshot.repositoryRoot,
                snapshot: snapshot
            )
            feedback = Feedback(kind: .success, message: summary)
            runningAction = nil
            await refresh(preserveFeedback: true)
        } catch {
            feedback = Feedback(kind: .error, message: error.localizedDescription)
            runningAction = nil
        }
    }

    func pull() async {
        guard let snapshot, canPull else { return }
        runningAction = .pulling
        feedback = nil
        do {
            let summary = try await AgentGitService.pull(repositoryRoot: snapshot.repositoryRoot)
            feedback = Feedback(kind: .success, message: summary)
            runningAction = nil
            await refresh(preserveFeedback: true)
        } catch {
            feedback = Feedback(kind: .error, message: error.localizedDescription)
            runningAction = nil
            await refresh(preserveFeedback: true)
        }
    }

    func cancelTasks() {
        activeDiffTask?.cancel()
        activeGenerateTask?.cancel()
    }

    private func loadDiffIfNeeded(for path: String) {
        guard diffsByPath[path] == nil,
              let snapshot,
              let file = snapshot.files.first(where: { $0.path == path })
        else { return }
        activeDiffTask?.cancel()
        loadingDiffPath = path
        activeDiffTask = Task { [weak self] in
            let diff = await AgentGitService.loadFileDiff(
                repositoryRoot: snapshot.repositoryRoot,
                file: file,
                hasHEAD: snapshot.hasHEAD
            )
            guard let self, !Task.isCancelled else { return }
            diffsByPath[path] = diff
            if loadingDiffPath == path {
                loadingDiffPath = nil
            }
        }
    }
}

/// Lightweight Git diff, selective staging/commit, push, and pull sheet for the Agent GUI.
struct AgentGitDiffSheet: View {
    let appearance: AgentAppearance
    @State private var state: AgentGitDiffState
    @Environment(\.dismiss) private var dismiss

    init(workingDirectory: String?, appearance: AgentAppearance) {
        self.appearance = appearance
        _state = State(initialValue: AgentGitDiffState(workingDirectory: workingDirectory))
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            if let feedback = state.feedback {
                feedbackBanner(feedback)
                Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            }
            contentBody
        }
        .foregroundStyle(MactermTheme.fg)
        .tint(MactermTheme.accent)
        .frame(minWidth: 800, idealWidth: 960, minHeight: 540, idealHeight: 660)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)))
        .task {
            await state.refresh()
        }
        .onDisappear {
            state.cancelTasks()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.body.weight(.medium))
                .foregroundStyle(MactermTheme.accent)
                .accessibilityHidden(true)

            if let snapshot = state.snapshot {
                HStack(spacing: 6) {
                    Text(verbatim: snapshot.displayBranch)
                        .font(appearance.headlineFont)
                        .lineLimit(1)
                    if let upstream = snapshot.upstream {
                        Text(verbatim: "→ \(upstream)")
                            .font(appearance.captionFont())
                            .foregroundStyle(MactermTheme.fgMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if !snapshot.files.isEmpty {
                        Text("(\(snapshot.files.count) changed)")
                            .font(appearance.captionFont())
                            .foregroundStyle(MactermTheme.fgMuted)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            } else {
                Text("Git Diff")
                    .font(appearance.headlineFont)
            }

            Spacer(minLength: 8)

            pullButton
            pushButton

            Button {
                Task { await state.refresh() }
            } label: {
                if state.runningAction == .refreshing {
                    ProgressView().controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(state.isBusy)
            .agentPointingHandCursor(!state.isBusy)
            .help(Text("Refresh Git status"))
            .accessibilityLabel(Text("Refresh Git status"))

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .agentPointingHandCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var pullButton: some View {
        let behind = state.snapshot?.behind ?? 0
        return Button {
            Task { await state.pull() }
        } label: {
            HStack(spacing: 4) {
                if state.runningAction == .pulling {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.down")
                }
                Text("Pull")
                if behind > 0 {
                    Text(verbatim: "\(behind)")
                        .font(appearance.captionFont(weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(MactermTheme.accent)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!state.canPull)
        .fixedSize()
        .agentPointingHandCursor(state.canPull)
        .help(Text("Pull latest changes from remote"))
    }

    private var pushButton: some View {
        let ahead = state.snapshot?.ahead ?? 0
        return Button {
            Task { await state.push() }
        } label: {
            HStack(spacing: 4) {
                if state.runningAction == .pushing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up")
                }
                Text("Push")
                if ahead > 0 {
                    Text(verbatim: "\(ahead)")
                        .font(appearance.captionFont(weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(MactermTheme.accent)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!state.canPush)
        .fixedSize()
        .agentPointingHandCursor(state.canPush)
        .help(Text("Push local commits to remote"))
    }

    private func feedbackBanner(_ feedback: AgentGitDiffState.Feedback) -> some View {
        let tint = feedback.kind == .error ? MactermTheme.failure : MactermTheme.success
        let icon = feedback.kind == .error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: feedback.message)
                .font(appearance.captionFont())
                .foregroundStyle(MactermTheme.fg)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                state.dismissFeedback()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(MactermTheme.fgMuted)
            }
            .buttonStyle(.plain)
            .agentPointingHandCursor()
            .accessibilityLabel(Text("Dismiss message"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    // MARK: - Body

    @ViewBuilder
    private var contentBody: some View {
        if let loadError = state.loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(MactermTheme.fgMuted)
                Text(verbatim: loadError)
                    .font(appearance.calloutFont())
                    .foregroundStyle(MactermTheme.fgMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if state.snapshot == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading Git changes…")
                    .font(appearance.captionFont())
                    .foregroundStyle(MactermTheme.fgMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                sidebarColumn
                    .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
                diffColumn
                    .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Left Column (Files + Commit Composer)

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            fileListHeader
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            if state.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundStyle(MactermTheme.success)
                    Text("Working tree clean")
                        .font(appearance.calloutFont())
                        .foregroundStyle(MactermTheme.fgMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.files) { file in
                            fileRow(file)
                        }
                    }
                    .padding(6)
                }
            }
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            commitSection
        }
        .background(MactermTheme.surface.opacity(0.45))
    }

    private var fileListHeader: some View {
        HStack(spacing: 8) {
            Button {
                state.toggleSelectAll()
            } label: {
                Image(systemName: selectAllIcon)
                    .font(.body)
                    .foregroundStyle(state.checkedCount > 0 ? MactermTheme.accent : MactermTheme.fgMuted)
            }
            .buttonStyle(.plain)
            .disabled(state.files.isEmpty || state.isBusy)
            .agentPointingHandCursor(!state.files.isEmpty && !state.isBusy)
            .help(state.allChecked ? Text("Deselect All") : Text("Select All"))
            .accessibilityLabel(state.allChecked ? Text("Deselect All") : Text("Select All"))

            Text("Changed Files")
                .font(appearance.captionFont(weight: .semibold))
                .foregroundStyle(MactermTheme.fgMuted)

            Spacer(minLength: 4)

            if !state.files.isEmpty {
                Text(verbatim: "\(state.checkedCount)/\(state.files.count)")
                    .font(appearance.captionFont())
                    .monospacedDigit()
                    .foregroundStyle(MactermTheme.fgMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectAllIcon: String {
        if state.allChecked { return "checkmark.square.fill" }
        if state.checkedCount > 0 { return "minus.square.fill" }
        return "square"
    }

    private func fileRow(_ file: AgentGitFileChange) -> some View {
        let isChecked = state.checkedPaths.contains(file.path)
        let isSelected = state.selectedPath == file.path
        return HStack(spacing: 8) {
            Button {
                state.toggleFileChecked(file.path)
            } label: {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isChecked ? MactermTheme.accent : MactermTheme.fgMuted)
            }
            .buttonStyle(.plain)
            .disabled(state.isBusy)
            .agentPointingHandCursor(!state.isBusy)
            .accessibilityLabel(isChecked ? Text("Exclude \(file.fileName)") : Text("Include \(file.fileName)"))

            Button {
                state.selectFile(file.path)
            } label: {
                HStack(spacing: 6) {
                    statusBadge(for: file)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: file.fileName)
                            .font(appearance.calloutFont(weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(MactermTheme.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let original = file.originalPath {
                            Text(verbatim: "\(original) → \(file.path)")
                                .font(appearance.captionFont())
                                .foregroundStyle(MactermTheme.fgMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else if let dir = file.directoryPath {
                            Text(verbatim: dir)
                                .font(appearance.captionFont())
                                .foregroundStyle(MactermTheme.fgMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    fileStatBadge(file)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .agentPointingHandCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected ? MactermTheme.accentSoft : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .help(Text(verbatim: file.path))
    }

    private func statusBadge(for file: AgentGitFileChange) -> some View {
        let color = statusColor(for: file.kind)
        return Text(verbatim: file.shortStatusCode)
            .font(appearance.codeFont(size: appearance.captionCodeSize, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func fileStatBadge(_ file: AgentGitFileChange) -> some View {
        if file.isBinary {
            Text(verbatim: "BIN")
                .font(appearance.codeFont(size: appearance.captionCodeSize))
                .foregroundStyle(MactermTheme.fgMuted)
        } else if file.additions > 0 || file.deletions > 0 {
            HStack(spacing: 4) {
                if file.additions > 0 {
                    Text(verbatim: "+\(file.additions)")
                        .foregroundStyle(MactermTheme.success)
                }
                if file.deletions > 0 {
                    Text(verbatim: "-\(file.deletions)")
                        .foregroundStyle(MactermTheme.failure)
                }
            }
            .font(appearance.codeFont(size: appearance.captionCodeSize))
            .monospacedDigit()
        }
    }

    private var commitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Commit Message")
                    .font(appearance.captionFont(weight: .semibold))
                    .foregroundStyle(MactermTheme.fgMuted)
                Spacer(minLength: 4)
                Button {
                    state.generateCommitMessage()
                } label: {
                    HStack(spacing: 4) {
                        if state.runningAction == .generatingMessage {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Generate")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!state.canGenerateCommitMessage)
                .fixedSize()
                .agentPointingHandCursor(state.canGenerateCommitMessage)
                .help(Text("Generate a commit message for the selected files"))
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.commitMessage)
                    .font(appearance.calloutFont())
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 82)
                if state.commitMessage.isEmpty {
                    Text("Write a commit message…")
                        .font(appearance.calloutFont())
                        .foregroundStyle(MactermTheme.fgMuted)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MactermTheme.border)
                    .allowsHitTesting(false)
            }

            Button {
                Task { await state.commit() }
            } label: {
                HStack(spacing: 6) {
                    if state.runningAction == .committing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    if state.checkedCount > 0 {
                        Text("Commit (\(state.checkedCount))")
                    } else {
                        Text("Commit")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!state.canCommit)
            .keyboardShortcut(.return, modifiers: .command)
            .agentPointingHandCursor(state.canCommit)
        }
        .padding(12)
    }

    // MARK: - Right Column (Diff Viewer)

    private var diffColumn: some View {
        VStack(spacing: 0) {
            if let file = state.selectedFile {
                diffFileHeader(file)
                Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
                diffContentView(for: file)
            } else if state.files.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle)
                        .foregroundStyle(MactermTheme.fgDim)
                    Text("No modified files to display")
                        .font(appearance.calloutFont())
                        .foregroundStyle(MactermTheme.fgMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Select a file to inspect its diff")
                    .font(appearance.calloutFont())
                    .foregroundStyle(MactermTheme.fgMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func diffFileHeader(_ file: AgentGitFileChange) -> some View {
        let diff = state.selectedDiff
        let additions = diff?.additions ?? file.additions
        let deletions = diff?.deletions ?? file.deletions
        return HStack(spacing: 8) {
            statusBadge(for: file)
            Text(verbatim: file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
                .font(appearance.codeFont(size: appearance.captionCodeSize, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if diff?.isBinary == true || file.isBinary {
                Text("Binary file")
                    .font(appearance.captionFont())
                    .foregroundStyle(MactermTheme.fgMuted)
            } else {
                HStack(spacing: 6) {
                    Text(verbatim: "+\(additions)")
                        .foregroundStyle(MactermTheme.success)
                    Text(verbatim: "-\(deletions)")
                        .foregroundStyle(MactermTheme.failure)
                }
                .font(appearance.codeFont(size: appearance.captionCodeSize, weight: .medium))
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(MactermTheme.surface.opacity(0.35))
    }

    @ViewBuilder
    private func diffContentView(for file: AgentGitFileChange) -> some View {
        if state.loadingDiffPath == file.path, state.selectedDiff == nil {
            VStack(spacing: 8) {
                ProgressView()
                Text("Loading diff…")
                    .font(appearance.captionFont())
                    .foregroundStyle(MactermTheme.fgMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let diff = state.selectedDiff {
            if diff.isBinary {
                VStack(spacing: 8) {
                    Image(systemName: "doc.fill")
                        .font(.title2)
                        .foregroundStyle(MactermTheme.fgMuted)
                    Text("Binary file — diff preview is not available.")
                        .font(appearance.calloutFont())
                        .foregroundStyle(MactermTheme.fgMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diff.lines.isEmpty {
                Text("No textual diff for this file.")
                    .font(appearance.calloutFont())
                    .foregroundStyle(MactermTheme.fgMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { line in
                            diffLineRow(line)
                        }
                        if diff.isTruncated {
                            Text("Diff output was truncated to keep the preview responsive.")
                                .font(appearance.captionFont())
                                .foregroundStyle(MactermTheme.fgMuted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .frame(minWidth: 460, alignment: .leading)
                    .padding(.vertical, 6)
                }
                .textSelection(.enabled)
            }
        } else {
            EmptyView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func diffLineRow(_ line: AgentGitDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: line.oldLineNumber.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(MactermTheme.fgDim)
                .padding(.trailing, 6)
            Text(verbatim: line.newLineNumber.map(String.init) ?? "")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(MactermTheme.fgDim)
                .padding(.trailing, 10)
            Text(verbatim: line.text.isEmpty ? " " : line.text)
                .foregroundStyle(diffLineForeground(line.kind))
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .font(appearance.codeFont(size: appearance.codeBlockSize))
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(diffLineBackground(line.kind))
    }

    private func statusColor(for kind: AgentGitFileChange.ChangeKind) -> Color {
        switch kind {
        case .added,
             .untracked:
            MactermTheme.success
        case .modified:
            MactermTheme.warning
        case .deleted,
             .conflicted:
            MactermTheme.failure
        case .renamed,
             .copied:
            MactermTheme.accent
        }
    }

    private func diffLineForeground(_ kind: AgentGitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: MactermTheme.success
        case .deletion: MactermTheme.failure
        case .hunk: MactermTheme.accent
        case .header,
             .note: MactermTheme.fgMuted
        case .context: MactermTheme.fg
        }
    }

    private func diffLineBackground(_ kind: AgentGitDiffLine.Kind) -> Color {
        switch kind {
        case .addition: MactermTheme.success.opacity(0.12)
        case .deletion: MactermTheme.failure.opacity(0.12)
        case .hunk: MactermTheme.accent.opacity(0.10)
        case .header,
             .note: MactermTheme.surface.opacity(0.5)
        case .context: Color.clear
        }
    }
}

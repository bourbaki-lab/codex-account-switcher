import CodexAccountSwitcherCore
import SwiftUI

struct ClaudeContentView: View {
    @ObservedObject var model: ClaudeDashboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            currentAccount
            Divider()
            otherAccounts
            controls
            status
        }
    }

    private var currentAccount: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Claude 현재 계정")
                Spacer()
                if model.report?.app != nil {
                    Text(model.isRunning ? "앱 실행 중" : "앱 종료됨")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let current = model.report?.currentPartition {
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(current.displayName).fontWeight(.semibold)
                    nicknameButton(current)
                    Spacer()
                    if let plan = current.label?.planName {
                        Text(plan)
                            .font(.caption)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.orange.opacity(0.12), in: Capsule())
                    }
                }
                Text("세션 \(current.sessionCount)개 · 대화 파일 있음 \(current.resumableCount)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                usage(current.usage)
            } else if model.report == nil {
                Label("Claude 계정 확인 중", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            } else {
                Label("현재 계정의 세션 목록 없음", systemImage: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func usage(_ sample: ClaudeUsageSample?) -> some View {
        if let sample {
            if let used = sample.fiveHourUsedPercent {
                usageWindow("5시간 한도", used: used)
            }
            if let used = sample.sevenDayUsedPercent {
                usageWindow("주간 한도", used: used)
            }
            Text("Claude 앱 사용률 기록 · \(sample.sampledAt.formatted(.dateTime.month().day().hour().minute()))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("이 계정의 사용률 기록이 아직 없습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func usageWindow(_ name: String, used: Int) -> some View {
        let remaining = min(max(100 - used, 0), 100)
        return VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: Double(remaining), total: 100)
            Text("\(name) \(remaining)% 남음")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var otherAccounts: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("다른 계정의 세션").font(.caption).foregroundStyle(.secondary)
            let others = model.report?.otherPartitions ?? []
            if others.isEmpty {
                Text("다른 계정의 세션 목록이 없습니다").font(.caption).foregroundStyle(.secondary)
            } else if others.count <= 3 {
                partitionRows(others)
            } else {
                ScrollView { partitionRows(others) }
                    .frame(height: 190)
            }
            Text("대화 파일은 계정과 관계없이 공유됩니다. 가져오기는 세션 목록 파일만 현재 계정에 복사합니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func partitionRows(_ partitions: [ClaudeAccountPartition]) -> some View {
        LazyVStack(alignment: .leading, spacing: 7) {
            ForEach(partitions) { partition in
                partitionRow(partition)
            }
        }
    }

    private func partitionRow(_ partition: ClaudeAccountPartition) -> some View {
        let importable = model.plans[partition.id]?.filesToCopy.count ?? 0
        return HStack(alignment: .top) {
            Image(systemName: "circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(partition.displayName)
                    nicknameButton(partition)
                }
                Text([partition.label?.planName, "세션 \(partition.sessionCount)개", "가져올 수 있음 \(importable)개"]
                    .compactMap { $0 }
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let last = partition.lastActivityAt {
                    Text("마지막 사용 \(last.formatted(.dateTime.month().day().hour().minute()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let summary = compactUsage(partition.usage) {
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
            Spacer()
            Button("가져오기") { model.requestCarryOver(from: partition) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.isBusy || importable == 0)
                .help(importable == 0
                    ? "대화 파일이 남아 있고 현재 계정 목록에 없는 세션이 없습니다"
                    : "이 계정의 세션 \(importable)개를 현재 계정 목록에 복사합니다")
        }
    }

    private func nicknameButton(_ partition: ClaudeAccountPartition) -> some View {
        Button {
            model.editNickname(accountUUID: partition.accountUUID, organizationUUID: partition.organizationUUID)
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(partition.label?.nickname == nil ? "별명 붙이기" : "별명 바꾸기 · \(partition.label?.maskedEmail ?? "")")
    }

    private func compactUsage(_ sample: ClaudeUsageSample?) -> String? {
        guard let sample else { return nil }
        let parts = [
            sample.fiveHourUsedPercent.map { "5시간 \(max(100 - $0, 0))%" },
            sample.sevenDayUsedPercent.map { "주간 \(max(100 - $0, 0))%" }
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return "\(parts.joined(separator: " · ")) 남음 · \(sample.sampledAt.formatted(.dateTime.month().day().hour().minute())) 기록"
    }

    private var controls: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 7) {
            GridRow {
                Button("Claude 앱 열기") { model.openClaude() }
                Button("계정 전환 안내") { model.guideAccountSwitch() }
                    .disabled(model.isBusy)
            }
            GridRow {
                Button("새로고침") { Task { await model.refresh() } }
                    .disabled(model.isBusy)
                Button("가져오기 되돌리기") { model.requestUndo() }
                    .disabled(model.isBusy || model.lastCarryOver == nil)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.statusMessage)
                .font(.caption)
                .foregroundStyle(model.statusMessage.contains("실패") || model.statusMessage.contains("없습니다:") ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let record = model.lastCarryOver {
                Text("마지막 가져오기 \(record.createdAt.formatted(.dateTime.month().day().hour().minute())) · \(record.copiedFiles.count)개 · 되돌리기 가능")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

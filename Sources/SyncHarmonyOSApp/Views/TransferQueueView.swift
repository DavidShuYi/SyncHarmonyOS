// TransferQueueView.swift — live transfer progress panel.

import SwiftUI
import SyncHarmonyCore

struct TransferQueueView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("传输队列")
                    .font(.headline)
                Spacer()
                Button("清除已完成") {
                    model.transfers.clearFinished()
                }
                .disabled(model.transfers.tasks.allSatisfy {
                    $0.state == .queued || $0.state == .running
                })
            }
            .padding()

            Divider()

            if model.transfers.tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("暂无传输任务")
                        .foregroundStyle(.secondary)
                    Text("把文件拖进窗口即可上传到手机")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.transfers.tasks) { task in
                    TransferRowView(task: task)
                }
                .listStyle(.plain)
            }
        }
    }
}

struct TransferRowView: View {
    @ObservedObject var task: TransferTask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(task.title)
                    .lineLimit(1)
                Spacer()
                stateBadge
            }
            ProgressView(value: task.fraction)
            HStack {
                Text("\(ByteCount.format(task.bytesDone)) / \(ByteCount.format(task.bytesTotal))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if case let .failed(message) = task.state {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .help(message)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch task.kind {
        case .download: return "arrow.down.circle"
        case .upload: return "arrow.up.circle"
        }
    }

    private var tint: Color {
        switch task.state {
        case .queued: return .secondary
        case .running: return .accentColor
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch task.state {
        case .queued:
            Text("排队中").font(.caption).foregroundStyle(.secondary)
        case .running:
            Text("传输中").font(.caption).foregroundStyle(.tint)
        case .finished:
            Label("完成", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed:
            Label("失败", systemImage: "xmark.circle.fill")
                .font(.caption).foregroundStyle(.red)
        case .cancelled:
            Text("已取消").font(.caption).foregroundStyle(.orange)
        }
    }
}

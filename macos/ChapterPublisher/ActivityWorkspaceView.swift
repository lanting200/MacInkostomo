import SwiftUI

struct ActivityWorkspaceView: View {
  @ObservedObject var model: WorkspaceModel

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        NativeSectionHeader("任务状态", subtitle: activitySubtitle)
        Spacer()
        NativeIconButton(
          title: "刷新任务",
          systemImage: "arrow.clockwise",
          disabled: model.isLoading
        ) {
          Task { await model.refreshActivity() }
        }
      }
      .padding(.horizontal, 14)
      .frame(height: 52)
      Divider()

      List {
        Section("章节工作流") {
          if generationJobs.isEmpty {
            Text("当前没有章节任务")
              .foregroundStyle(.secondary)
          } else {
            ForEach(generationJobs) { job in
              GenerationJobRow(job: job)
            }
          }
        }

        Section("建书工作流") {
          if creationJobs.isEmpty {
            Text("当前没有建书任务")
              .foregroundStyle(.secondary)
          } else {
            ForEach(creationJobs) { job in
              CreationJobRow(job: job)
            }
          }
        }

        Section("最近事件") {
          if model.debugEvents.isEmpty {
            Text("当前没有调试事件")
              .foregroundStyle(.secondary)
          } else {
            ForEach(model.debugEvents.prefix(200)) { event in
              HStack(alignment: .top, spacing: 10) {
                Text(event.level.uppercased())
                  .font(.caption2.monospaced().weight(.semibold))
                  .foregroundStyle(eventColor(event.level))
                  .frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                  Text(event.message)
                    .font(.callout)
                    .textSelection(.enabled)
                  Text("\(event.scope) · \(event.ts)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .listStyle(.inset)
    }
    .task { await model.refreshActivity() }
    .task(id: activeWorkflowIDs) {
      guard !activeWorkflowIDs.isEmpty else { return }
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: 2_000_000_000)
        } catch {
          return
        }
        await model.refreshWorkflowJobs()
        if model.activeGenerationJobs.isEmpty, model.activeCreationJobs.isEmpty {
          return
        }
      }
    }
  }

  private var generationJobs: [GenerationJob] {
    model.workflowJobs?.generationJobs.sorted {
      ($0.updatedAt ?? $0.startedAt ?? "") > ($1.updatedAt ?? $1.startedAt ?? "")
    } ?? []
  }

  private var creationJobs: [CreationJob] {
    model.workflowJobs?.creationJobs.sorted {
      ($0.updatedAt ?? $0.createdAt ?? "") > ($1.updatedAt ?? $1.createdAt ?? "")
    } ?? []
  }

  private var activitySubtitle: String {
    "运行中 \(model.activeGenerationJobs.count + model.activeCreationJobs.count)"
  }

  private var activeWorkflowIDs: String {
    let generationIDs = model.activeGenerationJobs.map { "generation:\($0.id)" }
    let creationIDs = model.activeCreationJobs.map { "creation:\($0.id)" }
    return (generationIDs + creationIDs).sorted().joined(separator: "|")
  }

  private func eventColor(_ level: String) -> Color {
    switch level.lowercased() {
    case "error": .red
    case "warn", "warning": .orange
    case "debug": .secondary
    default: .blue
    }
  }
}

private struct GenerationJobRow: View {
  let job: GenerationJob

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .opacity(job.isActive ? 1 : 0)
        .accessibilityHidden(!job.isActive)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        Text("\(job.bookId) · 第\(job.chapterNum)章\(job.title.map { " · \($0)" } ?? "")")
          .font(.callout.weight(.medium))
        Text(job.message ?? job.phase)
          .font(.caption)
          .foregroundStyle(job.error == nil ? Color.secondary : Color.red)
          .textSelection(.enabled)
      }
      Spacer()
      Text(job.phase)
        .font(.caption.monospaced())
        .foregroundStyle(job.isActive ? Color.blue : Color.secondary)
    }
  }
}

private struct CreationJobRow: View {
  let job: CreationJob

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      ProgressView()
        .controlSize(.small)
        .opacity(job.isActive ? 1 : 0)
        .accessibilityHidden(!job.isActive)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 3) {
        Text(job.title ?? job.bookId ?? job.jobId)
          .font(.callout.weight(.medium))
        Text(job.error ?? job.status)
          .font(.caption)
          .foregroundStyle(job.error == nil ? Color.secondary : Color.red)
          .textSelection(.enabled)
      }
      Spacer()
      Text(job.status)
        .font(.caption.monospaced())
        .foregroundStyle(job.isActive ? Color.blue : Color.secondary)
    }
  }
}

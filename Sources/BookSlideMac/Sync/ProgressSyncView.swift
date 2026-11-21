import SwiftUI
import UniformTypeIdentifiers

struct ProgressSyncView: View {
    @ObservedObject var reader: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                HStack {
                    Text("阅读进度同步").font(.title2.weight(.semibold))
                    Spacer()
                    Button("完成") { dismiss() }
                }
                Label("阅读进度自动保存在本机",systemImage:"checkmark.circle").font(.headline)
                Text("离线也能继续阅读。连接同一台 Mac 的手机会自动交换阅读进度。")
                    .font(.callout).foregroundStyle(.secondary)
                Divider()
                Label(reader.cloudSyncConfigured ? "文件夹同步已开启" : "跨设备同步",systemImage:"icloud").font(.headline)
                if reader.cloudSyncConfigured {
                    Text(reader.cloudFolderName ?? "已连接同步文件夹").font(.callout)
                    Text(reader.progressStatus).font(.caption).foregroundStyle(.secondary)
                    if reader.cloudFolderName == nil {
                        Button("重新选择同步文件夹") { choosingFolder = true }.disabled(reader.syncingProgress)
                    }
                    HStack {
                        Button(reader.syncingProgress ? "正在检查…" : "检查同步") { Task { await reader.syncProgress() } }
                        Spacer()
                        Menu("管理") {
                            Button("更换文件夹") { choosingFolder = true }
                            Button("关闭文件夹同步") { reader.disconnectProgressFolder() }
                        }
                    }.disabled(reader.syncingProgress)
                } else {
                    Text("在需要同步的设备上，选择 iCloud Drive 中的同一个文件夹。只需设置一次。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("选择同步文件夹") { choosingFolder = true }.buttonStyle(.borderedProminent).disabled(reader.syncingProgress)
                    Text(reader.progressStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text("这里只同步阅读位置；书籍需在各设备导入，书签保留在本机。阅读中收到新位置时，会先询问你是否继续。")
                    .font(.caption).foregroundStyle(.secondary)
                if let record = reader.pendingProgress {
                    Button("继续 \(record.deviceName) 的进度 · \(Int(record.progress*100))%") {
                        Task { if await reader.resumeSharedProgress() { dismiss() } }
                    }
                    .disabled(reader.busy || reader.loading || reader.handwritingActive)
                }
            }.padding(24)
        }
        #if os(macOS)
        .frame(width:460,height:460)
        #endif
        .fileImporter(isPresented:$choosingFolder,allowedContentTypes:[.folder]) { result in
            switch result {
            case .success(let url): Task { await reader.selectProgressFolder(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { reader.progressStatus = "文件夹未连接，请重新选择" }
            }
        }
    }
}

struct SharedProgressPrompt: View {
    @ObservedObject var reader: ReaderModel
    var body: some View {
        if let record = reader.pendingProgress, !reader.loading {
            HStack(spacing:12) {
                VStack(alignment:.leading,spacing:3) {
                    Text("\(record.deviceName) 有新的阅读位置").font(.caption.weight(.medium))
                    Text("\(Int(record.progress*100))% · \(record.updatedAt.formatted(date:.omitted,time:.shortened))").font(.caption2).foregroundStyle(.secondary)
                }
                Button("前往此处") { Task { await reader.resumeSharedProgress() } }.disabled(reader.busy).frame(minHeight:44)
                Button { reader.dismissedProgressID = record.id; reader.pendingProgress = nil } label: { Image(systemName:"xmark").frame(width:44,height:44) }.accessibilityLabel("保留当前阅读位置")
            }.padding(12).frame(maxWidth:460).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16)).padding(12)
        }
    }
}

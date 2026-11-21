import Foundation
import WebKit
#if os(iOS)
import UIKit
#endif
#if canImport(BookSlideCore)
import BookSlideCore
#endif

extension ReaderModel {
    #if os(iOS)
    func flushProgressInBackground() {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName:"Save reading progress") {
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
        }
        Task { @MainActor in
            // contentEditable node text is committed on blur. Backgrounding
            // does not reliably blur WebKit before iPadOS suspends the app.
            if let flush = mindMapInputFlush { _ = await flush.perform() }
            save()
            await syncProgress()
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
        }
    }
    #endif
    func recordProgress(_ position: EnginePosition) {
        let locator = position.viewport?.locator ?? position.locator
        guard let key = currentBook?.progressKey, let anchor = position.viewport?.anchor ?? position.anchor,
              locator != lastRecordedLocator else { return }
        let record = ReadingProgress(bookKey:key,deviceID:progressDeviceID,deviceName:progressDeviceName,anchor:anchor,cfi:locator,progress:position.progress)
        do {
            try progressStore.merge([record]); lastRecordedLocator = locator
            appliedProgressID = record.id; pendingProgress = nil
        } catch { progressStatus = "进度写入失败：\(error.localizedDescription)" }
    }
    @discardableResult @MainActor func restoreProgress(_ record: ReadingProgress) async throws -> Bool {
        guard !handwritingActive else { throw ReaderError.message("请先结束书写，再定位同步位置。") }
        #if os(iOS)
        guard inlineInk?.suspend() != false else { throw ReaderError.message("笔迹尚未保存，请重试") }
        #endif
        guard currentBook?.progressKey == record.bookKey else { throw ReaderError.message("同步位置不属于当前图书。") }
        let session = sessionID
        restoringProgress = true; defer { if sessionID == session { restoringProgress = false } }
        if let nativeBookReader {
            guard let position = nativeBookReader.go(to:record.anchor.href,userDriven:false) else {
                throw ReaderError.message("未能定位同步位置，请重试。")
            }
            acceptEnginePosition(position)
        } else {
            let data = try JSONEncoder().encode(record)
            let object = try JSONSerialization.jsonObject(with:data)
            let value = try await webView.callAsyncJavaScript("return await reader.restore(record)",arguments:["record":object],in:nil,contentWorld:.page)
            guard sessionID == session, !Task.isCancelled else { return false }
            guard let value, acceptPosition(value) else { throw ReaderError.message("未能定位同步位置，请重试。") }
        }
        appliedProgressID = record.id; lastRecordedLocator = position?.viewport?.locator ?? position?.locator; pendingProgress = nil
        save()
        return true
    }
    @discardableResult @MainActor func resumeSharedProgress() async -> Bool {
        guard let record = pendingProgress else { return false }
        guard !busy, !loading, !handwritingActive else {
            progressStatus = "请等当前操作完成，再定位同步位置。"; return false
        }
        let session = sessionID
        busy = true; defer { if sessionID == session { busy = false } }
        do {
            let restored = try await restoreProgress(record)
            if restored { progressStatus = "已继续同步位置" }
            return restored
        }
        catch {
            if sessionID == session { progressStatus = "无法定位同步位置：\(error.localizedDescription)" }
            return false
        }
    }
    @MainActor func syncProgress() async {
        guard !syncingProgress else { return }
        syncingProgress = true; defer { syncingProgress = false }
        let store = progressStore
        do {
            var cloudError: String?
            let result = await Task.detached(priority:.utility) { () -> String? in
                do { try store.syncCloud(); return nil }
                catch { return error.localizedDescription }
            }.value
            cloudError = result
            #if os(iOS)
            if externalSourcesEnabled, let connection = try? ConnectionStore.load() {
                let session = ReceiverClient.session(); defer { session.invalidateAndCancel() }
                do {
                    let records = try store.records()
                    let batches = stride(from:0,to:max(1,records.count),by:4)
                    for start in batches {
                        let incoming = try await ReceiverClient.progress(connection:connection,records:Array(records[start..<min(records.count,start+4)]),session:session)
                        guard (try? ConnectionStore.load())?.receiverID == connection.receiverID else { break }
                        try store.merge(incoming)
                    }
                    progressStatus = "设备进度已同步"
                } catch { progressStatus = "离线进度已保存 · 连接后自动同步" }
            }
            #endif
            if store.cloudConfigured {
                progressStatus = cloudError == nil ? "已与同步文件夹交换 · 云端传输由系统完成" : "云端暂不可用 · 本机进度已保留"
            }
            let records = try await Task.detached(priority:.utility) { try store.records() }.value
            for i in books.indices {
                guard let key = books[i].progressKey,
                      let latest = records.filter({$0.bookKey == key}).max(by:{$1.isNewer(than:$0)}) else { continue }
                if books[i].id != currentID {
                    books[i].progress = latest.progress; books[i].lastRead = max(books[i].lastRead,latest.updatedAt)
                } else if !loading, latest.id != appliedProgressID, latest.id != dismissedProgressID,
                          latest.deviceID != progressDeviceID {
                    pendingProgress = latest
                }
            }
            save()
        } catch { progressStatus = "进度暂未同步 · 本机记录已保留" }
    }
    @MainActor func selectProgressFolder(_ url: URL) async {
        guard !syncingProgress else { return }
        do {
            try progressStore.selectCloudFolder(url)
            cloudSyncConfigured = progressStore.cloudConfigured
            cloudFolderName = progressStore.cloudFolderName
            await syncProgress()
        }
        catch { progressStatus = "无法连接同步文件夹：\(error.localizedDescription)" }
    }
    @MainActor func disconnectProgressFolder() {
        guard !syncingProgress else { return }
        do {
            try progressStore.disconnectCloud()
            cloudSyncConfigured = false; cloudFolderName = nil
            progressStatus = "已关闭文件夹同步 · 本机进度保留"
        } catch { progressStatus = "未能关闭同步，请重试" }
    }
}

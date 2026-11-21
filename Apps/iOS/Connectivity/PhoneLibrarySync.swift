import Foundation

extension ReaderModel {
    func removeDownload(_ book: LibraryBook) {
        guard allowsLibraryWrites, book.remoteBookID != nil, book.id != currentID,
              let index = books.firstIndex(where: { $0.id == book.id }),
              !book.filename.isEmpty, (book.filename as NSString).lastPathComponent == book.filename else { return }
        do {
            let file = directory.appendingPathComponent(book.filename)
            var updated = books
            updated[index].filename = ""
            // Commit the index before deleting the only offline copy. A failed
            // index write must leave both the file and visible state intact.
            try LibraryIndexStore(directory:directory).save(updated)
            do {
                if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
            } catch {
                try LibraryIndexStore(directory:directory).save(books)
                throw error
            }
            books = updated
        } catch { self.error = "未能移除下载，请重试" }
    }
    func isDownloaded(_ book: LibraryBook) -> Bool {
        !book.filename.isEmpty && FileManager.default.fileExists(atPath:directory.appendingPathComponent(book.filename).path)
    }
    @MainActor func syncMacLibrary() async {
        guard externalSourcesEnabled else { return }
        guard !syncingLibrary else { libraryRefreshPending = true; return }
        guard let connection = try? ConnectionStore.load() else {
            // Mac sharing is optional. A first-time offline reader has nothing
            // to retry and can start with local books immediately.
            libraryMessage = nil; return
        }
        syncingLibrary = true
        defer {
            syncingLibrary = false
            if libraryRefreshPending {
                libraryRefreshPending = false
                Task { await syncMacLibrary() }
            }
        }
        let session = ReceiverClient.librarySession(); defer { session.invalidateAndCancel() }
        do {
            let reply = try await ReceiverClient.library(connection:connection,session:session)
            guard reply.ok, let catalog = reply.library else { throw ReaderError.message(reply.message) }
            guard (try? ConnectionStore.load())?.receiverID == connection.receiverID else { return }
            guard applyMacCatalog(catalog,receiverID:connection.receiverID) else {
                libraryMessage = "书目未能保存，请重试。已下载的书仍可阅读。"; return
            }
            libraryMessage = nil
        } catch { libraryMessage = "Mac 暂未连接，书目尚未更新。已下载的书仍可阅读。" }
    }
    @discardableResult func applyMacCatalog(_ catalog: [SharedLibraryBook], receiverID: UUID) -> Bool {
            guard allowsLibraryWrites else { return false }
            var updated = books
            var covers: [(UUID,Data)] = []
            let hidden = Set(UserDefaults.standard.stringArray(forKey:"hiddenRemoteBooks") ?? [])
            for item in catalog where !hidden.contains(receiverID.uuidString + "/" + item.id.uuidString) {
                guard let format = item.format else { continue }
                let index: Int
                if let existing = updated.firstIndex(where: { $0.remoteBookID == item.id && $0.remoteReceiverID == receiverID }) { index = existing }
                else if let key = item.progressKey, !key.isEmpty,
                        let local = updated.firstIndex(where: { $0.remoteBookID == nil && $0.progressKey == key && $0.format == format && isDownloaded($0) }) {
                    index = local
                    updated[index].remoteBookID = item.id; updated[index].remoteReceiverID = receiverID
                }
                else {
                    var book = LibraryBook(id:UUID(),title:item.title,author:item.author,filename:"")
                    book.remoteBookID = item.id; book.remoteReceiverID = receiverID; book.lastRead = item.lastRead
                    updated.append(book); index = updated.count-1
                }
                updated[index].title = item.title; updated[index].author = item.author
                updated[index].formatIdentifier = item.formatIdentifier
                if let key = item.progressKey { updated[index].progressKey = key }
                if let cover = item.cover, cover.count < 100_000, ReaderImage(data:cover) != nil {
                    covers.append((updated[index].id,cover))
                }
            }
            do { try LibraryIndexStore(directory:directory).save(updated) }
            catch { self.error = "Mac 书目未能保存，请重试。"; return false }
            books = updated
            for (id,cover) in covers { try? cover.write(to:directory.appendingPathComponent(id.uuidString + ".cover"),options:.atomic) }
            coverRevision += 1
            return true
    }
    @MainActor func openFromLibrary(_ id: UUID, connection requestedConnection: SavedConnection? = nil, session requestedSession: URLSession? = nil) async {
        guard downloadingBook == nil, let book = books.first(where: { $0.id == id }) else { return }
        let openingSession = sessionID
        error = nil
        if isDownloaded(book) { open(id); return }
        guard let sourceID = book.remoteBookID, let connection = requestedConnection ?? (try? ConnectionStore.load()), book.remoteReceiverID == connection.receiverID else {
            error = "请先连接这本书所在的 Mac"; return
        }
        downloadProgress = 0; downloadingBook = id; defer { downloadingBook = nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        let session = requestedSession ?? URLSession(configuration:config); defer { session.invalidateAndCancel() }
        do {
            var data = Data(), expected: Int?
            repeat {
                try Task.checkCancellation()
                let reply = try await ReceiverClient.library(connection:connection,book:sourceID,offset:data.count,session:session)
                guard reply.ok, let chunk = reply.libraryChunk else { throw ReaderError.message(reply.message) }
                guard chunk.id == sourceID, chunk.offset == data.count, chunk.total > 0,
                      chunk.total <= LibraryRouter.maximumSize, expected == nil || expected == chunk.total,
                      !chunk.data.isEmpty, chunk.data.count <= LibraryRouter.chunkSize,
                      data.count + chunk.data.count <= chunk.total else { throw ReceiverClient.Failure.invalidResponse }
                expected = chunk.total; data.append(chunk.data)
                downloadProgress = Double(data.count) / Double(chunk.total)
            } while data.count < (expected ?? 0)
            try Task.checkCancellation()
            guard let format = book.format else { throw BookImportFile.Failure.format }
            let downloaded = data
            let hash = try await Task.detached(priority:.userInitiated) {
                try BookImportFile.validate(downloaded, as:format)
                return BookImportFile.fingerprint(downloaded)
            }.value
            try Task.checkCancellation()
            guard let index = books.firstIndex(where: { $0.id == id }), books[index].format == format else {
                throw ReaderError.message("书目已更新，请重试下载")
            }
            if format == .pdf, let key = books[index].progressKey, hash != key {
                throw ReaderError.message("下载的书籍已变更，请更新 Mac 书目后重试")
            }
            if isDownloaded(books[index]) {
                if sessionID == openingSession, books[index].hidden != true { open(id) }
                return
            }
            let filename = UUID().uuidString + "." + format.rawValue
            let file = directory.appendingPathComponent(filename)
            try downloaded.write(to:file,options:.atomic)
            var updated = books
            updated[index].filename = filename
            updated[index].contentHash = hash
            do { try LibraryIndexStore(directory:directory).save(updated) }
            catch {
                try? FileManager.default.removeItem(at:file)
                throw error
            }
            books = updated
            if sessionID == openingSession, books[index].hidden != true { open(id) }
        } catch is CancellationError {
        } catch { if !Task.isCancelled { self.error = "下载未完成：\(error.localizedDescription)" } }
    }
}

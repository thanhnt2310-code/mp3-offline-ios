import Foundation

/// Import nhạc từ một thư mục cố định (ví dụ thư mục trong iCloud Drive đồng bộ với máy tính).
/// - Chỉ lấy file .mp3
/// - Chỉ copy bài chưa có (so theo tên file) vào bộ nhớ riêng của app để nghe offline
final class FolderImporter: ObservableObject {
    @Published var folderName: String?
    @Published var isImporting = false
    @Published var status: String?

    private let bookmarkKey = "sourceFolderBookmark"
    private let historyKey = "importedFileNames"

    init() {
        folderName = resolveFolderURL()?.lastPathComponent
    }

    // MARK: - Thư mục nguồn

    /// Lưu quyền truy cập thư mục người dùng vừa chọn (chỉ cần chọn một lần).
    func setFolder(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData() else {
            status = "Không lưu được quyền truy cập thư mục này."
            return
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        folderName = url.lastPathComponent
        status = nil
    }

    private func resolveFolderURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale {
            let access = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData() {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    // MARK: - Import

    /// Quét thư mục nguồn và copy các bài mp3 chưa có vào app.
    func importNew(into player: PlayerManager) {
        guard !isImporting else { return }
        guard let folder = resolveFolderURL() else {
            status = "Chưa chọn thư mục nguồn."
            return
        }
        isImporting = true
        status = "Đang quét thư mục..."
        let history = Set(UserDefaults.standard.stringArray(forKey: historyKey) ?? [])
        let destDir = PlayerManager.musicDir

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let access = folder.startAccessingSecurityScopedResource()
            defer { if access { folder.stopAccessingSecurityScopedResource() } }
            let fm = FileManager.default

            // 1. Quét thư mục, gom các file mp3 chưa có.
            var candidates: [(url: URL, name: String)] = []
            var seen = Set<String>()
            var skipped = 0
            if let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil,
                                      options: [.skipsPackageDescendants]) {
                for case let item as URL in en {
                    var name = item.lastPathComponent
                    var real = item
                    // File iCloud chưa tải về máy hiện dưới dạng ".TênBài.mp3.icloud".
                    if name.hasPrefix(".") && name.hasSuffix(".icloud") {
                        name = String(name.dropFirst().dropLast(7))
                        real = item.deletingLastPathComponent().appendingPathComponent(name)
                    }
                    guard name.lowercased().hasSuffix(".mp3"), !name.hasPrefix(".") else { continue }
                    if seen.contains(name) { continue }
                    seen.insert(name)
                    if history.contains(name) ||
                        fm.fileExists(atPath: destDir.appendingPathComponent(name).path) {
                        skipped += 1
                        continue
                    }
                    candidates.append((url: real, name: name))
                }
            }

            // 2. Copy từng bài mới. Đọc có điều phối (NSFileCoordinator) sẽ tự tải file từ iCloud nếu cần.
            let total = candidates.count
            var imported: [String] = []
            var failed = 0
            for (i, c) in candidates.enumerated() {
                DispatchQueue.main.async {
                    self?.status = "Đang import \(i + 1)/\(total): \(c.name)"
                }
                try? fm.startDownloadingUbiquitousItem(at: c.url)
                var coordError: NSError?
                var ok = false
                NSFileCoordinator().coordinate(readingItemAt: c.url, options: [], error: &coordError) { readURL in
                    do {
                        try fm.copyItem(at: readURL, to: destDir.appendingPathComponent(c.name))
                        ok = true
                    } catch {
                        print("Copy lỗi \(c.name): \(error)")
                    }
                }
                if ok { imported.append(c.name) } else { failed += 1 }
            }

            // 3. Ghi lại kết quả.
            let importedNames = imported
            let failedCount = failed
            let skippedCount = skipped
            DispatchQueue.main.async {
                guard let self else { return }
                var h = Set(UserDefaults.standard.stringArray(forKey: self.historyKey) ?? [])
                importedNames.forEach { h.insert($0) }
                UserDefaults.standard.set(Array(h), forKey: self.historyKey)
                self.isImporting = false
                var msg = importedNames.isEmpty && failedCount == 0
                    ? "Không có bài mới."
                    : "Đã thêm \(importedNames.count) bài mới"
                if skippedCount > 0 { msg += " (bỏ qua \(skippedCount) bài đã có)" }
                if failedCount > 0 { msg += ", lỗi \(failedCount) bài, hãy thử lại" }
                self.status = msg
                player.reload()
            }
        }
    }

    /// Xóa lịch sử import: lần sau sẽ thêm lại cả những bài đã xóa khỏi app.
    func resetHistory() {
        UserDefaults.standard.removeObject(forKey: historyKey)
        status = "Đã xóa lịch sử import."
    }
}

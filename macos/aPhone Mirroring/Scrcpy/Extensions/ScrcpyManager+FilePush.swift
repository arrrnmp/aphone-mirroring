//
//  ScrcpyManager+FilePush.swift
//  aPhone Mirroring
//
//  File drag-and-drop handling: APK installation and file push to /sdcard/Download/.
//
//  APK files   → `adb install -r`  (copied to a temp path first to resolve iCloud/alias)
//  Other files → `adb push` to /sdcard/Download/ + media scanner broadcast +
//                opens Downloads folder on device
//
//  Files are always staged through a temp directory before the adb subprocess reads
//  them, ensuring cloud placeholders and lazy drag-asset streams are fully materialised.
//

import Foundation

extension ScrcpyManager {

    // MARK: - File push (drag & drop)

    /// Pushes the given files to the connected Android device.
    /// APKs are installed via `adb install`; all other files go to `/sdcard/Download/`.
    func pushFiles(_ urls: [URL]) async {
        guard let serial = connectedSerial else { return }
        let serialArgs = ["-s", serial]

        let apkURLs  = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "apk" }
        let fileURLs = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() != "apk" }

        // ── APK installation ──────────────────────────────────────────────────
        for url in apkURLs {
            let filename = url.lastPathComponent
            log("Installing \(filename)…")
            // Copy to a temp path so iCloud/alias placeholders are resolved
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(filename)
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                try? FileManager.default.removeItem(at: tmp)
                try FileManager.default.copyItem(at: url, to: tmp)
            } catch {
                log("Could not read \(filename): \(error.localizedDescription)", level: .error)
                if accessed { url.stopAccessingSecurityScopedResource() }
                continue
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
            let result = await adb(serialArgs + ["install", "-r", tmp.path])
            try? FileManager.default.removeItem(at: tmp)
            if result.lowercased().contains("success") {
                log("Installed \(filename) ✓", level: .ok)
            } else {
                log("Install failed for \(filename): \(result.trimmingCharacters(in: .whitespacesAndNewlines))", level: .error)
            }
        }

        guard !fileURLs.isEmpty else { return }

        // ── Regular file push ─────────────────────────────────────────────────
        log("Pushing \(fileURLs.count) file(s) to /sdcard/Download/")

        // Copy each file to a temp dir so that:
        //   • Cloud/iCloud placeholders are fully materialised before adb reads them
        //   • Lazy-loaded drag assets (Photos.app, etc.) are resolved to real data
        //   • adb subprocess gets a simple, stable path without any alias indirection
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrcpy-push-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        struct PushItem { let src: URL; let filename: String }
        var items: [PushItem] = []

        for url in fileURLs {
            let filename = url.lastPathComponent
            let dst = tmp.appendingPathComponent(filename)
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                try FileManager.default.copyItem(at: url, to: dst)
                items.append(PushItem(src: dst, filename: filename))
            } catch {
                log("Could not read \(filename): \(error.localizedDescription)", level: .error)
            }
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        var pushedFilenames: [String] = []
        for item in items {
            log("Pushing \(item.filename)…")
            let result = await adb(serialArgs + ["push", item.src.path, "/sdcard/Download/\(item.filename)"])
            try? FileManager.default.removeItem(at: item.src)
            if result.lowercased().contains("error") || result.lowercased().contains("failed") {
                log("Push failed for \(item.filename): \(result.trimmingCharacters(in: .whitespacesAndNewlines))", level: .error)
            } else {
                log("Pushed \(item.filename) ✓", level: .ok)
                pushedFilenames.append(item.filename)
            }
        }
        try? FileManager.default.removeItem(at: tmp)

        // Notify media scanner for each pushed file
        for filename in pushedFilenames {
            await adb(serialArgs + [
                "shell", "am", "broadcast",
                "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                "-d", "file:///sdcard/Download/\(filename)"
            ])
        }

        // Open Downloads folder on device
        if !pushedFilenames.isEmpty {
            await adb(serialArgs + [
                "shell", "am", "start",
                "-a", "android.intent.action.VIEW",
                "-d", "content://com.android.externalstorage.documents/document/primary%3ADownload",
                "-t", "vnd.android.document/directory"
            ])
            log("Opened Downloads folder on device", level: .debug)
        }
    }
}

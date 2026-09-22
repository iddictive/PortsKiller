import AppKit
import Combine
import Foundation

@MainActor
final class GitHubUpdater: ObservableObject {
    static let shared = GitHubUpdater()

    private let repo = "iddictive/PortsKiller"
    private let defaults = UserDefaults.standard
    private let automaticChecksKey = "GitHubUpdater.automaticallyChecksForUpdates"
    private let automaticDownloadsKey = "GitHubUpdater.automaticallyDownloadsUpdates"

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let isAvailable = GitHubUpdater.isAvailable(bundleIdentifier: Bundle.main.bundleIdentifier, bundleURL: Bundle.main.bundleURL)
    private var manualFeedbackRequested = false
    private var releaseNotes: [String] = []

    nonisolated static func isAvailable(bundleIdentifier: String?, bundleURL: URL) -> Bool {
        bundleIdentifier == "com.md.PortsKiller" && bundleURL.standardizedFileURL.path == "/Applications/PortsKiller.app"
    }

    @Published var automaticallyChecksForUpdates: Bool {
        didSet {
            defaults.set(automaticallyChecksForUpdates, forKey: automaticChecksKey)
            if !automaticallyChecksForUpdates {
                automaticallyDownloadsUpdates = false
            }
        }
    }

    @Published var automaticallyDownloadsUpdates: Bool {
        didSet {
            defaults.set(automaticallyDownloadsUpdates, forKey: automaticDownloadsKey)
        }
    }

    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var downloadURL: URL?
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var error: String?

    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    private init() {
        automaticallyChecksForUpdates = defaults.object(forKey: automaticChecksKey) as? Bool ?? true
        automaticallyDownloadsUpdates = defaults.object(forKey: automaticDownloadsKey) as? Bool ?? false
    }

    func checkForUpdates(manual: Bool = false) {
        guard isAvailable else {
            if manual {
                _ = runUpdaterAlert(messageText: "Updates unavailable", informativeText: "Open the installed PortsKiller app in Applications to check for updates.", primaryButtonTitle: "OK")
            }
            return
        }
        if manual { manualFeedbackRequested = true }
        guard !isChecking else { return }
        guard manual || automaticallyChecksForUpdates else { return }

        isChecking = true
        error = nil

        Task { [weak self] in
            guard let self else { return }

            do {
                let release = try await latestRelease()
                let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
                latestVersion = latest
                updateAvailable = compareVersions(current: currentVersion, latest: latest)
                downloadURL = updateAvailable ? release.dmgAssetURL : nil
                guard !updateAvailable || downloadURL != nil else { throw UpdaterError.missingAsset }
                releaseNotes = UpdateReleaseNotes.summaryLines(from: release.body ?? "")
                if releaseNotes.isEmpty {
                    releaseNotes = await changelogNotes(tag: release.tagName, version: latest)
                }
                let showFeedback = manualFeedbackRequested
                manualFeedbackRequested = false
                isChecking = false

                if updateAvailable {
                    if showFeedback {
                        showUpdateAlert(version: latest)
                    } else if automaticallyDownloadsUpdates {
                        startDownload()
                    }
                } else if showFeedback {
                    _ = runUpdaterAlert(
                        messageText: "PortsKiller is up to date",
                        informativeText: withReleaseNotes("Installed version \(currentVersion) is the latest version."),
                        primaryButtonTitle: "OK"
                    )
                }
            } catch {
                self.error = error.localizedDescription
                updateAvailable = false
                downloadURL = nil
                isChecking = false
                let showFeedback = manualFeedbackRequested
                manualFeedbackRequested = false
                if showFeedback {
                    _ = runUpdaterAlert(messageText: "Couldn’t check for updates", informativeText: error.localizedDescription, primaryButtonTitle: "OK")
                }
            }

            isChecking = false
        }
    }

    func startDownload() {
        guard isAvailable else { return }
        guard let downloadURL, !isDownloading else { return }

        isDownloading = true
        downloadProgress = 0
        error = nil

        downloadTask = URLSession.shared.downloadTask(with: downloadURL) { [weak self] localURL, response, downloadError in
            // URLSession removes its temporary file when this callback returns.
            // Preserve it before crossing to the main actor.
            let downloadedFile: Result<URL, Error> = Result {
                if let downloadError { throw downloadError }
                guard let localURL, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw UpdaterError.downloadFailed
                }
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("PortsKillerUpdate.dmg")
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: localURL, to: tempURL)
                return tempURL
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isDownloading = false
                self.observation = nil

                do {
                    let tempURL = try downloadedFile.get()
                    self.performInstallation(dmgPath: tempURL.path)
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }

        observation = downloadTask?.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        downloadTask?.resume()
    }

    private func latestRelease() async throws -> GitHubRelease {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("PortsKillerUpdater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw UpdaterError.latestReleaseUnavailable
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private func compareVersions(current: String, latest: String) -> Bool {
        latest.compare(current, options: .numeric) == .orderedDescending
    }

    private func changelogNotes(tag: String, version: String) async -> [String] {
        guard let tag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(tag)/CHANGELOG.md") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let markdown = String(data: data, encoding: .utf8) else { return [] }
        return UpdateReleaseNotes.releaseNotes(from: markdown, version: version)
    }

    private func withReleaseNotes(_ base: String) -> String {
        guard !releaseNotes.isEmpty else { return base }
        return base + "\n\nWhat’s new:\n" + releaseNotes.map { "• " + $0 }.joined(separator: "\n")
    }

    private func showUpdateAlert(version: String) {
        let response = runUpdaterAlert(
            messageText: "Update Available",
            informativeText: withReleaseNotes("PortsKiller \(version) is available. Download and install it now?"),
            primaryButtonTitle: "Download & Install",
            secondaryButtonTitle: "Later"
        )

        if response == .alertFirstButtonReturn {
            startDownload()
        }
    }

    private func performInstallation(dmgPath: String) {
        let response = runUpdaterAlert(
            messageText: "Installation Ready",
            informativeText: withReleaseNotes("PortsKiller will close, install the downloaded update, and relaunch."),
            primaryButtonTitle: "Install & Relaunch",
            secondaryButtonTitle: "Later"
        )

        if response == .alertFirstButtonReturn {
            runInstallScript(dmgPath: dmgPath)
        }
    }

    @discardableResult
    private func runUpdaterAlert(
        messageText: String,
        informativeText: String,
        primaryButtonTitle: String,
        secondaryButtonTitle: String? = nil
    ) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.icon = updaterAlertIcon()

        let primaryButton = alert.addButton(withTitle: primaryButtonTitle)
        primaryButton.keyEquivalent = "\r"

        if let secondaryButtonTitle {
            let secondaryButton = alert.addButton(withTitle: secondaryButtonTitle)
            secondaryButton.keyEquivalent = "\u{1b}"
        }

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal()
    }

    private func updaterAlertIcon() -> NSImage? {
        if let appIcon = NSApp.applicationIconImage, appIcon.isValid {
            return sizedAlertIcon(appIcon)
        }

        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL)
        else { return nil }

        return sizedAlertIcon(icon)
    }

    private func sizedAlertIcon(_ icon: NSImage) -> NSImage {
        guard let copy = icon.copy() as? NSImage else { return icon }
        copy.size = NSSize(width: 64, height: 64)
        return copy
    }

    private func runInstallScript(dmgPath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let expectedVersion = latestVersion ?? ""
        guard expectedVersion.range(of: #"^\d+(?:\.\d+)+$"#, options: .regularExpression) != nil else {
            error = "Invalid update version."
            return
        }
        let script = """
        set -eu
        logPath="/tmp/PortsKillerUpdate.log"
        appPath="/Applications/PortsKiller.app"
        mountPath="/tmp/portskiller_update"
        stagedAppPath="/tmp/PortsKiller.updated.app"
        backupAppPath="/tmp/PortsKiller.previous.app"
        dmgPath="\(dmgPath)"
        expectedVersion="\(expectedVersion)"
        executableName="PortsKiller"
        needsRollback=0

        exec >> "$logPath" 2>&1

        log() {
            printf '%s %s\\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
        }

        rollback() {
            log "Rolling back to previous app"
            pkill -x "$executableName" 2>/dev/null || true
            rm -rf "$appPath"
            if [ -d "$backupAppPath" ]; then
                ditto "$backupAppPath" "$appPath"
                open "$appPath"
                log "Rollback complete"
            else
                log "Rollback skipped: backup missing"
            fi
        }

        finish() {
            status=$?
            if [ "$status" -ne 0 ] && [ "$needsRollback" = "1" ]; then
                rollback
            fi
            hdiutil detach "$mountPath" -quiet 2>/dev/null || true
            rm -rf "$mountPath" "$stagedAppPath"
            exit "$status"
        }
        trap finish EXIT

        log "Starting update install"
        while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done

        rm -rf "$mountPath" "$stagedAppPath"
        mkdir -p "$mountPath"
        hdiutil attach "$dmgPath" -mountpoint "$mountPath" -nobrowse -quiet

        sourceAppPath="$mountPath/PortsKiller.app"
        if [ ! -x "$sourceAppPath/Contents/MacOS/$executableName" ]; then
            log "Staged app is missing executable"
            exit 1
        fi

        ditto "$sourceAppPath" "$stagedAppPath"
        xattr -rc "$stagedAppPath" || true
        codesign --verify --deep --strict "$stagedAppPath"

        stagedBundleID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$stagedAppPath/Contents/Info.plist" 2>/dev/null || true)"
        if [ "$stagedBundleID" != "com.md.PortsKiller" ]; then
            log "Staged app has unexpected bundle identifier: $stagedBundleID"
            exit 1
        fi

        stagedVersion="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$stagedAppPath/Contents/Info.plist" 2>/dev/null || true)"
        if [ -z "$stagedVersion" ]; then
            log "Staged app version is missing"
            exit 1
        fi
        if [ -n "$expectedVersion" ] && [ "$stagedVersion" != "$expectedVersion" ]; then
            log "Staged app version $stagedVersion does not match expected $expectedVersion"
            exit 1
        fi

        rm -rf "$backupAppPath"
        if [ -d "$appPath" ]; then
            ditto "$appPath" "$backupAppPath"
            needsRollback=1
        fi

        rm -rf "$appPath"
        ditto "$stagedAppPath" "$appPath"
        log "Installed version $stagedVersion"

        open "$appPath"
        smokePassed=0
        for _ in {1..30}; do
            sleep 0.5
            if pgrep -x "$executableName" >/dev/null; then
                sleep 3
                if pgrep -x "$executableName" >/dev/null; then
                    smokePassed=1
                    break
                fi
            fi
        done

        if [ "$smokePassed" != "1" ]; then
            log "Smoke launch failed"
            exit 1
        fi

        needsRollback=0
        rm -rf "$backupAppPath"
        log "Update install succeeded"
        """

        do {
            try launchDetachedShellScript(script)
            NSApp.terminate(nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func launchDetachedShellScript(_ script: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        try process.run()
    }
}

struct GitHubRelease: Decodable {
    let tagName: String
    let assets: [GitHubReleaseAsset]
    let body: String?

    var dmgAssetURL: URL? {
        assets.first { asset in
            asset.name.hasSuffix(".dmg") && asset.name.localizedCaseInsensitiveContains("PortsKiller")
        }?.browserDownloadURL
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
        case body
    }
}

struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private enum UpdaterError: LocalizedError {
    case latestReleaseUnavailable
    case missingAsset
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .latestReleaseUnavailable:
            return "Latest release is unavailable."
        case .missingAsset:
            return "The release does not include a PortsKiller DMG."
        case .downloadFailed:
            return "The update could not be downloaded."
        }
    }
}

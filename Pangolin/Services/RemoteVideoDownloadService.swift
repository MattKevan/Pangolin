import Foundation
import Darwin

enum RemoteVideoProvider: String, Codable {
    case youtube

    static func detect(from url: URL) -> RemoteVideoProvider? {
        guard let host = url.host?.lowercased() else { return nil }
        let supportedHosts = [
            "youtube.com",
            "www.youtube.com",
            "m.youtube.com",
            "youtu.be"
        ]
        return supportedHosts.contains(host) ? .youtube : nil
    }
}

enum RemoteVideoDownloadError: LocalizedError {
    case invalidURL
    case unsupportedProvider
    case playlistNotSupported
    case toolNotFound(String)
    case processLaunchFailed(String)
    case processControlFailed(String)
    case downloadFailed(String)
    case outputFileNotFound

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .unsupportedProvider:
            return "This URL is not supported yet. v1 supports YouTube video URLs only."
        case .playlistNotSupported:
            return "Playlists are not supported yet. Please paste a single video URL."
        case .toolNotFound(let tool):
            return "Required downloader tool not found: \(tool)."
        case .processLaunchFailed(let details):
            return "Failed to launch downloader: \(details)"
        case .processControlFailed(let details):
            return "Could not control downloader process: \(details)"
        case .downloadFailed(let details):
            return "Download failed: \(details)"
        case .outputFileNotFound:
            return "Download completed but the output file could not be located."
        }
    }
}

struct RemoteVideoProbeResult {
    let provider: RemoteVideoProvider
    let title: String?
    let videoIdentifier: String?
}

struct RemoteVideoDownloadResult {
    let provider: RemoteVideoProvider
    let localFileURL: URL
    let title: String?
    let originalURL: URL
    let videoIdentifier: String?
}

final class RemoteVideoDownloadService {
    private struct DownloaderCommand {
        let executableURL: URL
        let baseArguments: [String]
        let environment: [String: String]?
        let displayName: String
    }

    struct ProgressUpdate {
        let fractionCompleted: Double?
        let message: String
    }

    private var currentProcess: Process?
    private var currentProcessPaused = false
    private let fileManager = FileManager.default
    private let progressRegex = try? NSRegularExpression(pattern: #"^\[download\]\s+(\d+(?:\.\d+)?)%"#)

    func probe(url: URL) async throws -> RemoteVideoProbeResult {
        guard let provider = RemoteVideoProvider.detect(from: url) else {
            throw RemoteVideoDownloadError.unsupportedProvider
        }
        if isPlaylistURL(url) {
            throw RemoteVideoDownloadError.playlistNotSupported
        }

        let downloader = try resolveDownloaderCommand()
        let ffmpegURL = resolveFFmpeg()
        print("🌐 DOWNLOAD: Using downloader command \(downloader.displayName)")

        let output = try await runProcess(
            executableURL: downloader.executableURL,
            arguments: downloader.baseArguments + [
                "--skip-download",
                "--no-playlist",
                "--no-warnings",
                "--print", "TITLE:%(title)s",
                "--print", "VIDEO_ID:%(id)s",
                url.absoluteString
            ],
            environment: downloader.environment,
            currentDirectoryURL: nil,
            ffmpegURL: ffmpegURL,
            progressHandler: nil
        )

        if output.terminationStatus != 0 {
            let details = output.stderr.nonEmpty
                ?? output.stdout.nonEmpty
                ?? "yt-dlp probe exited with status \(output.terminationStatus)"
            throw RemoteVideoDownloadError.downloadFailed(details)
        }

        let title = extractTaggedLine(prefix: "TITLE:", from: output.stdout)
        let videoIdentifier = extractTaggedLine(prefix: "VIDEO_ID:", from: output.stdout)
        return RemoteVideoProbeResult(provider: provider, title: title, videoIdentifier: videoIdentifier)
    }

    func downloadVideo(
        from url: URL,
        progressHandler: (@Sendable (ProgressUpdate) -> Void)? = nil
    ) async throws -> RemoteVideoDownloadResult {
        let probeResult = try await probe(url: url)

        let downloader = try resolveDownloaderCommand()
        let ffmpegURL = resolveFFmpeg()
        let stagingDirectory = try makeTaskStagingDirectory()

        let outputTemplate = "%(title).200B.%(ext)s"
        let output = try await runProcess(
            executableURL: downloader.executableURL,
            arguments: downloader.baseArguments + [
                "--newline",
                "--no-playlist",
                "--progress",
                "--no-warnings",
                "--no-color",
                "--merge-output-format", "mp4",
                "-o", outputTemplate,
                "--print", "after_move:FILEPATH:%(filepath)s",
                url.absoluteString
            ],
            environment: downloader.environment,
            currentDirectoryURL: stagingDirectory,
            ffmpegURL: ffmpegURL,
            progressHandler: progressHandler
        )

        if output.terminationStatus != 0 {
            let details = output.stderr.nonEmpty ?? output.stdout.nonEmpty ?? "Unknown yt-dlp error"
            throw RemoteVideoDownloadError.downloadFailed(details)
        }

        let finalPath = output.stdout
            .split(separator: "\n")
            .map(String.init)
            .compactMap { line -> String? in
                guard line.hasPrefix("FILEPATH:") else { return nil }
                return String(line.dropFirst("FILEPATH:".count))
            }
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalURL: URL?
        if let finalPath, !finalPath.isEmpty {
            finalURL = URL(fileURLWithPath: finalPath)
        } else {
            finalURL = try? fileManager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)
                .first(where: { $0.hasDirectoryPath == false })
        }

        guard let localFileURL = finalURL,
              fileManager.fileExists(atPath: localFileURL.path) else {
            throw RemoteVideoDownloadError.outputFileNotFound
        }

        return RemoteVideoDownloadResult(
            provider: probeResult.provider,
            localFileURL: localFileURL,
            title: probeResult.title,
            originalURL: url,
            videoIdentifier: probeResult.videoIdentifier
        )
    }

    func pauseCurrentDownload() throws {
        guard let process = currentProcess else {
            throw RemoteVideoDownloadError.processControlFailed("No active download.")
        }
        guard !currentProcessPaused else { return }
        let pid = process.processIdentifier
        guard pid > 0 else {
            throw RemoteVideoDownloadError.processControlFailed("Invalid process identifier.")
        }
        guard Darwin.kill(pid, SIGSTOP) == 0 else {
            throw RemoteVideoDownloadError.processControlFailed(String(cString: strerror(errno)))
        }
        currentProcessPaused = true
    }

    func resumeCurrentDownload() throws {
        guard let process = currentProcess else {
            throw RemoteVideoDownloadError.processControlFailed("No paused download.")
        }
        guard currentProcessPaused else { return }
        let pid = process.processIdentifier
        guard pid > 0 else {
            throw RemoteVideoDownloadError.processControlFailed("Invalid process identifier.")
        }
        guard Darwin.kill(pid, SIGCONT) == 0 else {
            throw RemoteVideoDownloadError.processControlFailed(String(cString: strerror(errno)))
        }
        currentProcessPaused = false
    }

    func stopCurrentDownload() {
        currentProcessPaused = false
        currentProcess?.terminate()
    }

    func isRemoteStagingURL(_ url: URL) -> Bool {
        url.path.hasPrefix(Self.stagingRootDirectory().path)
    }

    func cleanupStagingArtifacts(for fileURL: URL) {
        guard isRemoteStagingURL(fileURL) else { return }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
            let parent = fileURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: parent.path),
               (try? fileManager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).isEmpty) == true {
                try fileManager.removeItem(at: parent)
            }
        } catch {
            print("⚠️ REMOTE DOWNLOAD: Failed cleaning staging artifacts for \(fileURL.path): \(error)")
        }
    }

    // MARK: - Helpers

    private struct ProcessOutput {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    private final class ProcessOutputAccumulator {
        private let lock = NSLock()
        private var stdout = Data()
        private var stderr = Data()

        func appendStdout(_ data: Data) {
            lock.lock()
            stdout.append(data)
            lock.unlock()
        }

        func appendStderr(_ data: Data) {
            lock.lock()
            stderr.append(data)
            lock.unlock()
        }

        func snapshot() -> (stdout: Data, stderr: Data) {
            lock.lock()
            let out = stdout
            let err = stderr
            lock.unlock()
            return (out, err)
        }
    }

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        currentDirectoryURL: URL?,
        ffmpegURL: URL?,
        progressHandler: (@Sendable (ProgressUpdate) -> Void)?
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executableURL
            var resolvedArgs = arguments
            if let ffmpegURL {
                let ffmpegArgs = ["--ffmpeg-location", ffmpegURL.deletingLastPathComponent().path]
                let insertionIndex = ytDlpOptionInsertionIndex(in: resolvedArgs)
                resolvedArgs.insert(contentsOf: ffmpegArgs, at: insertionIndex)
            }
            process.arguments = resolvedArgs
            process.currentDirectoryURL = currentDirectoryURL
            if let environment {
                process.environment = environment
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let accumulator = ProcessOutputAccumulator()

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                accumulator.appendStdout(data)
                if let progressHandler, let chunk = String(data: data, encoding: .utf8) {
                    self?.emitProgress(from: chunk, handler: progressHandler)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                accumulator.appendStderr(data)
            }

            process.terminationHandler = { [weak self] proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let remainingOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingOut.isEmpty { accumulator.appendStdout(remainingOut) }
                let remainingErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                if !remainingErr.isEmpty { accumulator.appendStderr(remainingErr) }

                let snapshot = accumulator.snapshot()
                let stdout = String(data: snapshot.stdout, encoding: .utf8) ?? ""
                let stderr = String(data: snapshot.stderr, encoding: .utf8) ?? ""

                Task { @MainActor in
                    if self?.currentProcess?.processIdentifier == proc.processIdentifier {
                        self?.currentProcess = nil
                        self?.currentProcessPaused = false
                    }
                }

                continuation.resume(returning: ProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    terminationStatus: proc.terminationStatus
                ))
            }

            do {
                try process.run()
                Task { @MainActor in
                    self.currentProcess = process
                    self.currentProcessPaused = false
                }
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: RemoteVideoDownloadError.processLaunchFailed(error.localizedDescription))
            }
        }
    }

    private func ytDlpOptionInsertionIndex(in arguments: [String]) -> Int {
        guard let moduleFlagIndex = arguments.firstIndex(of: "-m"),
              moduleFlagIndex + 1 < arguments.count,
              arguments[moduleFlagIndex + 1] == "yt_dlp" else {
            return 0
        }
        return moduleFlagIndex + 2
    }

    private func emitProgress(from chunk: String, handler: @Sendable (ProgressUpdate) -> Void) {
        for line in chunk.split(whereSeparator: \.isNewline) {
            let text = String(line)
            guard text.hasPrefix("[download]") else { continue }

            if let fraction = parseDownloadProgress(line: text) {
                handler(.init(fractionCompleted: fraction, message: text))
            } else {
                handler(.init(fractionCompleted: nil, message: text))
            }
        }
    }

    private func parseDownloadProgress(line: String) -> Double? {
        guard let progressRegex,
              let match = progressRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line),
              let percent = Double(line[range]) else {
            return nil
        }
        return max(0.0, min(1.0, percent / 100.0))
    }

    private func extractTaggedLine(prefix: String, from text: String) -> String? {
        text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .first(where: { $0.hasPrefix(prefix) })?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private func isPlaylistURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        if components.path.lowercased() == "/playlist" {
            return true
        }

        return components.queryItems?.contains(where: { item in
            item.name.caseInsensitiveCompare("list") == .orderedSame &&
            (item.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }) == true
    }

    private func resolveDownloaderCommand() throws -> DownloaderCommand {
        if let embedded = resolveEmbeddedPythonDownloader() {
            return embedded
        }
        let ytDlpURL = try resolveYtDlp()
        return DownloaderCommand(
            executableURL: ytDlpURL,
            baseArguments: [],
            environment: nil,
            displayName: ytDlpURL.lastPathComponent
        )
    }

    private func resolveEmbeddedPythonDownloader() -> DownloaderCommand? {
        guard let toolsRoot = toolsRootURL() else { return nil }
        guard let pythonURL = bundledPythonExecutable(in: toolsRoot) else { return nil }

        let sitePackages = toolsRoot.appendingPathComponent("site-packages", isDirectory: true)
        let ytDlpPackage = sitePackages.appendingPathComponent("yt_dlp", isDirectory: true)
        guard fileManager.fileExists(atPath: ytDlpPackage.path) else { return nil }

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUTF8"] = "1"

        let pythonHome = toolsRoot.appendingPathComponent("python", isDirectory: true)
        if fileManager.fileExists(atPath: pythonHome.path) {
            environment["PYTHONHOME"] = pythonHome.path
        }

        let existingPythonPath = environment["PYTHONPATH"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingPythonPath, !existingPythonPath.isEmpty {
            environment["PYTHONPATH"] = "\(sitePackages.path):\(existingPythonPath)"
        } else {
            environment["PYTHONPATH"] = sitePackages.path
        }

        let certifiPem = sitePackages
            .appendingPathComponent("certifi", isDirectory: true)
            .appendingPathComponent("cacert.pem")
        if fileManager.fileExists(atPath: certifiPem.path) {
            environment["SSL_CERT_FILE"] = certifiPem.path
            environment["REQUESTS_CA_BUNDLE"] = certifiPem.path
        }

        return DownloaderCommand(
            executableURL: pythonURL,
            baseArguments: ["-m", "yt_dlp"],
            environment: environment,
            displayName: "python -m yt_dlp"
        )
    }

    private func bundledPythonExecutable(in toolsRoot: URL) -> URL? {
        let candidates = [
            toolsRoot.appendingPathComponent("python/bin/python3"),
            toolsRoot.appendingPathComponent("python/bin/python"),
            toolsRoot.appendingPathComponent("python3"),
            toolsRoot.appendingPathComponent("python")
        ]

        if let explicit = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return explicit
        }

        let pythonBinDir = toolsRoot.appendingPathComponent("python/bin", isDirectory: true)
        if let files = try? fileManager.contentsOfDirectory(at: pythonBinDir, includingPropertiesForKeys: nil),
           let discovered = files
            .filter({ fileManager.isExecutableFile(atPath: $0.path) })
            .first(where: { $0.lastPathComponent.hasPrefix("python3") }) {
            return discovered
        }
        return nil
    }

    private func resolveYtDlp() throws -> URL {
        if let bundled = bundledTool(named: "yt-dlp") { return bundled }

        let fallbackPaths = [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/usr/bin/yt-dlp"
        ]

        if let path = fallbackPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        throw RemoteVideoDownloadError.toolNotFound("yt-dlp")
    }

    private func resolveFFmpeg() -> URL? {
        if let bundled = bundledTool(named: "ffmpeg") { return bundled }

        let fallbackPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]

        guard let path = fallbackPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func bundledTool(named name: String) -> URL? {
        let candidates: [URL?] = [
            toolsRootURL()?.appendingPathComponent(name),
            Bundle.main.resourceURL?.appendingPathComponent(name)
        ]

        for candidate in candidates.compactMap({ $0 }) where fileManager.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private func toolsRootURL() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true)
    }

    private func makeTaskStagingDirectory() throws -> URL {
        let root = Self.stagingRootDirectory()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func stagingRootDirectory() -> URL {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return appSupport.appendingPathComponent("Pangolin", isDirectory: true)
                .appendingPathComponent("RemoteDownloads", isDirectory: true)
        }
        return fm.temporaryDirectory.appendingPathComponent("PangolinRemoteDownloads", isDirectory: true)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

//
//  VideoPlayerViewModel.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// ViewModels/VideoPlayerViewModel.swift
import Foundation
import AVFoundation
import Combine
#if os(macOS)
import AppKit
import AVKit
#endif

class VideoPlayerViewModel: NSObject, ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoading = false
    @Published var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }
    @Published var playbackRate: Float = 1.0
    @Published var availableSubtitles: [Subtitle] = []
    @Published var selectedSubtitle: Subtitle?
    @Published var currentVideo: Video?
    @Published var isExternalPlaybackActive = false

    #if os(macOS)
    weak var playerView: AVPlayerView?
    private var externalWindow: NSWindow?
    private var externalPlayerView: AVPlayerView?
    #endif
    
    private var timeObserver: Any?
    private var playbackEndedCancellable: AnyCancellable?
    private var durationStatusCancellable: AnyCancellable?
    private var playerStateCancellable: AnyCancellable?
    private var buildTask: Task<Void, Never>?
    private var pendingSeek: (videoID: UUID?, seconds: TimeInterval)?
    
    override init() {
        super.init()
    }

    // Cache directory for converted VTT files from SRT
    private lazy var subtitlesCacheDirectory: URL? = {
        do {
            let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("Pangolin/Subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            print("⚠️ Failed to create subtitles cache directory: \(error)")
            return nil
        }
    }()
    
    func loadVideo(_ video: Video, autoPlay: Bool = false) {
        currentVideo = video
        isLoading = true
        let shouldAutoPlay = autoPlay
        currentTime = resumePosition(for: video) ?? 0
        let pendingSeekForVideo: TimeInterval? = {
            guard let pendingSeek, pendingSeek.videoID == video.id else { return nil }
            return pendingSeek.seconds
        }()
        if pendingSeekForVideo != nil {
            pendingSeek = nil
        }
        
        // Collect subtitles
        if let subs = video.subtitles as? Set<Subtitle> {
            availableSubtitles = Array(subs).sorted { $0.displayName < $1.displayName }
        } else {
            availableSubtitles = []
        }
        
        // Cancel any in-flight build
        buildTask?.cancel()
        buildTask = Task { @MainActor in
            resetPlayerObservers()
            do {
                let resolvedURL = try await video.getAccessibleFileURL(downloadIfNeeded: true)
                do {
                    let item = try await buildPlayerItem(for: resolvedURL, with: selectedSubtitle)
                    let newPlayer = AVPlayer(playerItem: item)
                    newPlayer.volume = volume
                    player = newPlayer
                    observePlaybackState(for: newPlayer)
                    
                    // Also ensure duration is updated (in case builder didn't)
                    await updateDuration(from: item)
                    
                    // Prefer a pending explicit seek target; otherwise resume if not fully watched.
                    if let startPosition = pendingSeekForVideo ?? resumePosition(for: video) {
                        await player?.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
                        currentTime = startPosition
                    }
                    
                    await setupTimeObserverIfAsync()
                    await setupNotificationsIfAsync()
                    if shouldAutoPlay {
                        play()
                    }
                } catch {
                    // Fallback to simple item on failure
                    let item = AVPlayerItem(url: resolvedURL)
                    let newPlayer = AVPlayer(playerItem: item)
                    newPlayer.volume = volume
                    player = newPlayer
                    observePlaybackState(for: newPlayer)
                    await updateDuration(from: item)
                    if let startPosition = pendingSeekForVideo ?? resumePosition(for: video) {
                        await player?.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
                        currentTime = startPosition
                    }
                    await setupTimeObserverIfAsync()
                    await setupNotificationsIfAsync()
                    if shouldAutoPlay {
                        play()
                    }
                    print("⚠️ Failed to build composed player item: \(error)")
                }
            } catch {
                print("🚨 Failed to resolve playable video URL: \(error)")
            }
            isLoading = false
        }
    }
    
    func play() {
        player?.rate = playbackRate
        player?.play()
        isPlaying = true
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }
    
    func seek(to time: TimeInterval) {
        let target = max(0, time.isFinite ? time : 0)
        guard let player else {
            currentTime = target
            if let currentVideo {
                currentVideo.playbackPosition = target
                pendingSeek = (currentVideo.id, target)
                if !isLoading {
                    loadVideo(currentVideo, autoPlay: isPlaying)
                }
            }
            return
        }

        let wasPlaying = isPlaying || player.rate != 0
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)

        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if wasPlaying {
                    self.player?.play()
                    self.player?.rate = self.playbackRate
                    self.isPlaying = true
                } else {
                    self.player?.pause()
                    self.isPlaying = false
                }
                self.currentTime = target
            }
        }
    }

    func seek(to time: TimeInterval, in video: Video) {
        let target = max(0, time.isFinite ? time : 0)
        let isSameVideo = currentVideo?.id == video.id

        if isSameVideo, player != nil {
            seek(to: target)
            return
        }

        pendingSeek = (video.id, target)
        currentTime = target
        video.playbackPosition = target

        if isSameVideo {
            if !isLoading {
                loadVideo(video, autoPlay: isPlaying)
            }
            return
        }

        loadVideo(video, autoPlay: false)
    }
    
    func skipForward(_ seconds: TimeInterval = 10) {
        let newTime = currentTime + seconds
        seek(to: min(newTime, duration))
    }
    
    func skipBackward(_ seconds: TimeInterval = 10) {
        let newTime = currentTime - seconds
        seek(to: max(newTime, 0))
    }
    
    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        player?.rate = isPlaying ? rate : 0
    }
    
    func selectSubtitle(_ subtitle: Subtitle?) {
        selectedSubtitle = subtitle
        guard let video = currentVideo, let url = video.fileURL else { return }
        
        let wasPlaying = isPlaying
        let current = currentTime
        
        // Cancel any in-flight build
        buildTask?.cancel()
        buildTask = Task { @MainActor in
            do {
                let item = try await buildPlayerItem(for: url, with: subtitle)
                // Ensure duration updated for UI
                await updateDuration(from: item)
                player?.replaceCurrentItem(with: item)
            } catch {
                print("⚠️ Failed to rebuild player item with subtitle: \(error)")
                let fallback = AVPlayerItem(url: url)
                await updateDuration(from: fallback)
                player?.replaceCurrentItem(with: fallback)
            }
            // Restore time and play state
            await player?.seek(to: CMTime(seconds: current, preferredTimescale: 600))
            if wasPlaying { play() } else { pause() }
        }
    }

    // MARK: - External Playback Options

#if os(macOS)
    func togglePictureInPicture() {
        guard let playerView else { return }
        let selector = NSSelectorFromString("togglePictureInPicture:")
        if playerView.responds(to: selector) {
            playerView.perform(selector, with: nil)
        }
    }

    func openInNewWindow() {
        guard let player else { return }

        if let window = externalWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let playerView = AVPlayerView()
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = currentVideo?.title ?? "Pangolin Player"
        window.contentView = playerView
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        externalWindow = window
        externalPlayerView = playerView
        isExternalPlaybackActive = true
    }
    #endif
    
    // MARK: - Async composition builder
    
    @MainActor
    private func buildPlayerItem(for videoURL: URL, with subtitle: Subtitle?) async throws -> AVPlayerItem {
        // If no subtitle requested, return the plain item
        guard let subtitle, let legibleAsset = legibleAsset(for: subtitle) else {
            let item = AVPlayerItem(url: videoURL)
            await updateDuration(from: item)
            return item
        }
        
        let videoAsset = AVURLAsset(url: videoURL)
        let composition = AVMutableComposition()
        
        // Add video + audio tracks
        do {
            let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            let audioTracks = try await videoAsset.loadTracks(withMediaType: .audio)
            let duration = try await videoAsset.load(.duration)
            
            for track in videoTracks {
                if let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                }
            }
            for track in audioTracks {
                if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                }
            }
        } catch {
            print("⚠️ Failed to build base composition: \(error).")
            let item = AVPlayerItem(url: videoURL)
            await updateDuration(from: item)
            return item
        }
        
        // Add legible track
        do {
            let textTracks = try await legibleAsset.loadTracks(withMediaType: .text)
            if let textTrack = textTracks.first,
               let compText = composition.addMutableTrack(withMediaType: .text, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let compDuration = try await composition.load(.duration)
                try compText.insertTimeRange(CMTimeRange(start: .zero, duration: compDuration), of: textTrack, at: .zero)
            } else {
                print("⚠️ Legible asset has no text tracks")
            }
        } catch {
            print("⚠️ No .text tracks in legible asset: \(error)")
        }
        
        let item = AVPlayerItem(asset: composition)
        await updateDuration(from: item)
        return item
    }
    
    private func legibleAsset(for subtitle: Subtitle) -> AVAsset? {
        guard let sourceURL = subtitle.fileURL else { return nil }
        let ext = sourceURL.pathExtension.lowercased()
        
        if ext == "vtt" {
            return AVURLAsset(url: sourceURL)
        } else if ext == "srt" {
            // Convert to VTT in cache
            guard let cacheDir = subtitlesCacheDirectory else { return nil }
            let vttURL = cacheDir.appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent + ".vtt")
            if FileManager.default.fileExists(atPath: vttURL.path) == false {
                do {
                    let srtText = try String(contentsOf: sourceURL, encoding: .utf8)
                    let vttText = convertSRTtoVTT(srtText)
                    try vttText.data(using: .utf8)?.write(to: vttURL, options: .atomic)
                } catch {
                    print("⚠️ Failed converting SRT to VTT: \(error)")
                    return nil
                }
            }
            return AVURLAsset(url: vttURL)
        } else {
            // Unsupported format for now
            return nil
        }
    }
    
    private func convertSRTtoVTT(_ srt: String) -> String {
        // Simple conversion: prepend WEBVTT and convert commas to dots in timecodes
        let lines = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var output: [String] = ["WEBVTT", ""]
        
        let timecodeRegex = try? NSRegularExpression(pattern: #"(\d{2}:\d{2}:\d{2}),(\d{3})\s-->\s(\d{2}:\d{2}:\d{2}),(\d{3})"#)
        
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty || Int(line) != nil {
                i += 1
                continue
            }
            if let regex = timecodeRegex,
               let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {
                let ns = line as NSString
                let start = "\(ns.substring(with: match.range(at: 1))).\(ns.substring(with: match.range(at: 2)))"
                let end = "\(ns.substring(with: match.range(at: 3))).\(ns.substring(with: match.range(at: 4)))"
                output.append("\(start) --> \(end)")
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    output.append(lines[i])
                    i += 1
                }
                output.append("")
            } else {
                i += 1
            }
        }
        
        return output.joined(separator: "\n")
    }
    
    // MARK: - Observers & state
    
    @MainActor
    private func setupTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.currentTime = CMTimeGetSeconds(time)
            
            if let duration = self.player?.currentItem?.duration {
                self.duration = CMTimeGetSeconds(duration)
            }
            
            self.savePlaybackPosition()
        }
    }
    
    @MainActor
    private func setupNotifications() {
        playbackEndedCancellable?.cancel()
        playbackEndedCancellable = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in
                self?.handlePlaybackEnded()
            }
    }
    
    // Helpers to call setup methods conditionally with await if the async overload exists
    @MainActor
    private func setupTimeObserverIfAsync() async {
        // Call the sync version
        setupTimeObserver()
    }
    
    @MainActor
    private func setupNotificationsIfAsync() async {
        // Call the sync version
        setupNotifications()
    }
    
    @MainActor
    private func updateDuration(from item: AVPlayerItem) async {
        if item.status == .readyToPlay {
            duration = CMTimeGetSeconds(item.duration)
            durationStatusCancellable?.cancel()
        } else {
            // Wait for readyToPlay
            durationStatusCancellable?.cancel()
            durationStatusCancellable = item.publisher(for: \.status)
                .filter { $0 == .readyToPlay }
                .sink { [weak self, weak item] _ in
                    if let d = item?.duration {
                        self?.duration = CMTimeGetSeconds(d)
                    }
                }
        }
    }

    @MainActor
    private func resetPlayerObservers() {
        removeTimeObserver()
        playbackEndedCancellable?.cancel()
        playbackEndedCancellable = nil
        durationStatusCancellable?.cancel()
        durationStatusCancellable = nil
        playerStateCancellable?.cancel()
        playerStateCancellable = nil
    }

    @MainActor
    private func removeTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
    
    private func savePlaybackPosition() {
        currentVideo?.playbackPosition = currentTime
    }
    
    private func handlePlaybackEnded() {
        isPlaying = false
        if let video = currentVideo {
            if video.duration > 0 {
                video.playbackPosition = video.duration
            }
            video.playCount += 1
            video.lastPlayed = Date()
        }
    }

    private func resumePosition(for video: Video) -> TimeInterval? {
        let position = video.playbackPosition
        guard position.isFinite, position > 0 else { return nil }

        let totalDuration = video.duration
        guard totalDuration.isFinite, totalDuration > 0 else {
            return position
        }

        let progress = position / totalDuration
        let remaining = totalDuration - position

        // Treat near-end playback as fully watched and restart from the beginning.
        if progress >= 0.99 || remaining <= 1.0 {
            return nil
        }

        return position
    }

    @MainActor
    private func observePlaybackState(for player: AVPlayer) {
        playerStateCancellable?.cancel()
        playerStateCancellable = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
        isPlaying = player.timeControlStatus == .playing
    }
    
    deinit {
        playbackEndedCancellable?.cancel()
        durationStatusCancellable?.cancel()
        playerStateCancellable?.cancel()
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        buildTask?.cancel()
    }
}

#if os(macOS)
extension VideoPlayerViewModel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           window == externalWindow {
            externalWindow = nil
            externalPlayerView = nil
            isExternalPlaybackActive = false
        }
    }
}
#endif

import os
//
//  VideoPlayerViewModel.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// ViewModels/VideoPlayerViewModel.swift
import Foundation
@preconcurrency import AVFoundation
import Combine
#if os(macOS)
import AppKit
import AVKit
#endif

enum VideoPlaybackSelection {
    enum Action: Equatable {
        case load
        case clear
        case none
    }

    static func action(
        selectedID: UUID?,
        isVideoDetailActive: Bool,
        loadedID: UUID?
    ) -> Action {
        guard isVideoDetailActive, let selectedID else { return .clear }
        return selectedID == loadedID ? .none : .load
    }

    static func isVideoChange(from loadedID: UUID?, to selectedID: UUID?) -> Bool {
        guard let loadedID else { return false }
        return loadedID != selectedID
    }
}

enum VideoAspectRatioSelection {
    static func initialRatio(
        loadedVideoID: UUID?,
        selectedVideoID: UUID?,
        currentRatio: CGFloat,
        persistedResolution: String?
    ) -> CGFloat {
        if let selectedVideoID,
           loadedVideoID == selectedVideoID,
           currentRatio.isFinite,
           currentRatio > 0 {
            return currentRatio
        }

        return VideoFloatingLayout.aspectRatio(for: persistedResolution)
    }
}

enum VideoPlaybackOperation {
    struct Token: Equatable {
        let generation: UInt
        let videoID: UUID?
    }

    static func isCurrent(
        _ token: Token,
        generation: UInt,
        videoID: UUID?
    ) -> Bool {
        token.generation == generation && token.videoID == videoID
    }

    static func ownsLoading(_ token: Token, owner: Token?) -> Bool {
        token == owner
    }
}

struct VideoPosterPresentationState: Equatable {
    private(set) var videoID: UUID?
    private(set) var isDismissed = false

    mutating func prepare(for videoID: UUID) {
        guard self.videoID != videoID else { return }
        self.videoID = videoID
        isDismissed = false
    }

    mutating func dismiss(for videoID: UUID) {
        guard self.videoID == videoID else { return }
        isDismissed = true
    }

    mutating func clear() {
        videoID = nil
        isDismissed = false
    }

    func isDismissed(for videoID: UUID) -> Bool {
        self.videoID == videoID && isDismissed
    }
}

@MainActor
@Observable
class VideoPlayerViewModel: NSObject {
    var player: AVPlayer?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var isLoading = false
    var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }
    var playbackRate: Float = 1.0
    var availableSubtitles: [Subtitle] = []
    var selectedSubtitle: Subtitle?
    var currentVideo: Video?
    var isExternalPlaybackActive = false
    private(set) var videoAspectRatio = VideoFloatingLayout.fallbackAspectRatio
    private(set) var posterPresentation = VideoPosterPresentationState()

    #if os(macOS)
    @ObservationIgnored weak var playerView: AVPlayerView?
    @ObservationIgnored private var externalWindow: NSWindow?
    @ObservationIgnored private var externalPlayerView: AVPlayerView?
    #endif
    
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeObserverOwner: AVPlayer?
    @ObservationIgnored private var playbackEndedCancellable: AnyCancellable?
    @ObservationIgnored private var durationStatusCancellable: AnyCancellable?
    @ObservationIgnored private var playerStateCancellable: AnyCancellable?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSeek: (videoID: UUID?, seconds: TimeInterval)?
    @ObservationIgnored private var lastPersistedPosition: TimeInterval = 0
    @ObservationIgnored private var loadGeneration: UInt = 0
    @ObservationIgnored private var loadingOperation: VideoPlaybackOperation.Token?
    
    override init() {
        super.init()
    }

    // Cache directory for converted VTT files from SRT
    @ObservationIgnored private lazy var subtitlesCacheDirectory: URL? = {
        do {
            let base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("Pangolin/Subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            Logger.player.warning("Failed to create subtitles cache directory: \(error)")
            return nil
        }
    }()
    
    func loadVideo(_ video: Video, autoPlay: Bool = false) {
        let isVideoChange = VideoPlaybackSelection.isVideoChange(
            from: currentVideo?.id,
            to: video.id
        )
        if isVideoChange {
            persistPlaybackPosition()
        }
        buildTask?.cancel()
        loadGeneration &+= 1
        let token = VideoPlaybackOperation.Token(
            generation: loadGeneration,
            videoID: video.id
        )

        if isVideoChange {
            discardPlayerForVideoChange()
        }

        videoAspectRatio = VideoAspectRatioSelection.initialRatio(
            loadedVideoID: currentVideo?.id,
            selectedVideoID: video.id,
            currentRatio: videoAspectRatio,
            persistedResolution: video.resolution
        )
        if let videoID = video.id {
            posterPresentation.prepare(for: videoID)
        } else {
            posterPresentation.clear()
        }
        currentVideo = video
        beginLoading(token)
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
        
        buildTask = Task { @MainActor in
            defer { finishLoading(token) }
            guard isCurrentOperation(token) else { return }
            resetPlayerObservers()
            do {
                let resolvedURL = try await video.getAccessibleFileURL(downloadIfNeeded: true)
                guard isCurrentOperation(token) else { return }
                await updateDisplayAspectRatio(for: resolvedURL, token: token)
                guard isCurrentOperation(token) else { return }
                do {
                    let item = try await buildPlayerItem(for: resolvedURL, with: selectedSubtitle)
                    guard isCurrentOperation(token) else { return }
                    await installLoadedItem(
                        item,
                        token: token,
                        startPosition: pendingSeekForVideo ?? resumePosition(for: video),
                        autoPlay: shouldAutoPlay
                    )
                } catch {
                    guard isCurrentOperation(token) else { return }
                    // Fallback to simple item on failure
                    let item = AVPlayerItem(url: resolvedURL)
                    await installLoadedItem(
                        item,
                        token: token,
                        startPosition: pendingSeekForVideo ?? resumePosition(for: video),
                        autoPlay: shouldAutoPlay
                    )
                    if isCurrentOperation(token) {
                        Logger.player.warning("Failed to build composed player item: \(error)")
                    }
                }
            } catch {
                if isCurrentOperation(token) {
                    Logger.player.error("Failed to resolve playable video URL: \(error)")
                }
            }
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
        persistPlaybackPosition()
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func dismissPoster(for videoID: UUID) {
        posterPresentation.dismiss(for: videoID)
    }

    func isPosterDismissed(for videoID: UUID) -> Bool {
        posterPresentation.isDismissed(for: videoID)
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

        let activePlayer = player
        let token = VideoPlaybackOperation.Token(
            generation: loadGeneration,
            videoID: currentVideo?.id
        )
        let wasPlaying = isPlaying || activePlayer.rate != 0
        let targetTime = CMTime(seconds: target, preferredTimescale: 600)

        activePlayer.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak activePlayer] _ in
            Task { @MainActor in
                guard let self,
                      let activePlayer,
                      self.isCurrentOperation(token, expectedPlayer: activePlayer) else { return }
                if wasPlaying {
                    activePlayer.play()
                    activePlayer.rate = self.playbackRate
                    self.isPlaying = true
                } else {
                    activePlayer.pause()
                    self.isPlaying = false
                }
                self.currentTime = target
                self.persistPlaybackPosition()
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
        // A different video resets currentTime itself when it loads; setting it here would
        // make the outgoing video's position look like the new target.
        if isSameVideo {
            currentTime = target
        }
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
        guard let video = currentVideo,
              let url = video.fileURL,
              let activePlayer = player else { return }
        
        let wasPlaying = isPlaying
        let current = currentTime
        
        buildTask?.cancel()
        loadGeneration &+= 1
        let token = VideoPlaybackOperation.Token(
            generation: loadGeneration,
            videoID: video.id
        )
        beginLoading(token)
        buildTask = Task { @MainActor in
            defer { finishLoading(token) }
            guard isCurrentOperation(token, expectedPlayer: activePlayer) else { return }
            let item: AVPlayerItem
            do {
                item = try await buildPlayerItem(for: url, with: subtitle)
                guard isCurrentOperation(token, expectedPlayer: activePlayer) else { return }
            } catch {
                guard isCurrentOperation(token, expectedPlayer: activePlayer) else { return }
                Logger.player.warning("Failed to rebuild player item with subtitle: \(error)")
                item = AVPlayerItem(url: url)
            }

            guard isCurrentOperation(token, expectedPlayer: activePlayer) else { return }
            updateDuration(from: item, token: token, expectedPlayer: activePlayer)
            activePlayer.replaceCurrentItem(with: item)
            observePlaybackState(for: activePlayer, token: token)
            setupTimeObserver(for: activePlayer, token: token)
            setupNotifications(for: activePlayer, token: token)

            // Restore time and play state
            await activePlayer.seek(to: CMTime(seconds: current, preferredTimescale: 600))
            guard isCurrentOperation(token, expectedPlayer: activePlayer) else { return }
            if wasPlaying {
                activePlayer.rate = playbackRate
                activePlayer.play()
                isPlaying = true
            } else {
                activePlayer.pause()
                isPlaying = false
            }
        }
    }

    func clearLoadedVideo() {
        persistPlaybackPosition()
        buildTask?.cancel()
        loadGeneration &+= 1
        resetPlayerObservers()
        player?.pause()
        player = nil
        currentVideo = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        loadingOperation = nil
        isLoading = false
        videoAspectRatio = VideoFloatingLayout.fallbackAspectRatio
        posterPresentation.clear()
    }

    private func discardPlayerForVideoChange() {
        resetPlayerObservers()
        player?.pause()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func isCurrentOperation(
        _ token: VideoPlaybackOperation.Token,
        expectedPlayer: AVPlayer? = nil
    ) -> Bool {
        guard !Task.isCancelled,
              VideoPlaybackOperation.isCurrent(
                token,
                generation: loadGeneration,
                videoID: currentVideo?.id
              ) else {
            return false
        }
        return expectedPlayer == nil || player === expectedPlayer
    }

    private func beginLoading(_ token: VideoPlaybackOperation.Token) {
        loadingOperation = token
        isLoading = true
    }

    private func finishLoading(_ token: VideoPlaybackOperation.Token) {
        guard VideoPlaybackOperation.ownsLoading(token, owner: loadingOperation) else { return }
        loadingOperation = nil
        isLoading = false
    }

    private func updateDisplayAspectRatio(
        for url: URL,
        token: VideoPlaybackOperation.Token
    ) async {
        do {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard isCurrentOperation(token), let videoTrack = tracks.first else { return }

            let naturalSize = try await videoTrack.load(.naturalSize)
            guard isCurrentOperation(token) else { return }

            let preferredTransform = try await videoTrack.load(.preferredTransform)
            guard isCurrentOperation(token),
                  let displaySize = VideoDisplayGeometry.displaySize(
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform
                  ) else {
                return
            }

            let ratio = displaySize.width / displaySize.height
            guard isCurrentOperation(token), ratio.isFinite, ratio > 0 else { return }
            videoAspectRatio = ratio
        } catch {
            guard isCurrentOperation(token) else { return }
            // The safe fallback remains active when source display metadata is unavailable.
        }
    }

    private func installLoadedItem(
        _ item: AVPlayerItem,
        token: VideoPlaybackOperation.Token,
        startPosition: TimeInterval?,
        autoPlay: Bool
    ) async {
        guard isCurrentOperation(token) else { return }

        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.volume = volume
        player = newPlayer
        observePlaybackState(for: newPlayer, token: token)
        updateDuration(from: item, token: token, expectedPlayer: newPlayer)

        if let startPosition {
            await newPlayer.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
            guard isCurrentOperation(token, expectedPlayer: newPlayer) else { return }
            currentTime = startPosition
        }

        guard isCurrentOperation(token, expectedPlayer: newPlayer) else { return }
        setupTimeObserver(for: newPlayer, token: token)
        setupNotifications(for: newPlayer, token: token)
        if autoPlay {
            newPlayer.rate = playbackRate
            newPlayer.play()
            isPlaying = true
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
    
    private func buildPlayerItem(for videoURL: URL, with subtitle: Subtitle?) async throws -> AVPlayerItem {
        // If no subtitle requested, return the plain item
        guard let subtitle, let legibleAsset = legibleAsset(for: subtitle) else {
            return AVPlayerItem(url: videoURL)
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
                    let preferredTransform = try await track.load(.preferredTransform)
                    try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                    compTrack.preferredTransform = preferredTransform
                }
            }
            for track in audioTracks {
                if let compTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
                }
            }
        } catch {
            Logger.player.warning("Failed to build base composition: \(error).")
            return AVPlayerItem(url: videoURL)
        }
        
        // Add legible track
        do {
            let textTracks = try await legibleAsset.loadTracks(withMediaType: .text)
            if let textTrack = textTracks.first,
               let compText = composition.addMutableTrack(withMediaType: .text, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let compDuration = try await composition.load(.duration)
                try compText.insertTimeRange(CMTimeRange(start: .zero, duration: compDuration), of: textTrack, at: .zero)
            } else {
                Logger.player.warning("Legible asset has no text tracks")
            }
        } catch {
            Logger.player.warning("No .text tracks in legible asset: \(error)")
        }
        
        return AVPlayerItem(asset: composition)
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
                    Logger.player.warning("Failed converting SRT to VTT: \(error)")
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
    
    private func setupTimeObserver(
        for player: AVPlayer,
        token: VideoPlaybackOperation.Token
    ) {
        removeTimeObserver()
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverOwner = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            Task { @MainActor in
                guard let self,
                      let player,
                      self.isCurrentOperation(token, expectedPlayer: player) else { return }
                self.currentTime = CMTimeGetSeconds(time)

                if let duration = player.currentItem?.duration {
                    self.duration = CMTimeGetSeconds(duration)
                }

                self.persistPlaybackPositionIfNeeded()
            }
        }
    }
    
    private func setupNotifications(
        for player: AVPlayer,
        token: VideoPlaybackOperation.Token
    ) {
        playbackEndedCancellable?.cancel()
        playbackEndedCancellable = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self, weak player] notification in
                Task { @MainActor in
                    guard let self,
                          let player,
                          self.isCurrentOperation(token, expectedPlayer: player),
                          notification.object as AnyObject? === player.currentItem else { return }
                    self.handlePlaybackEnded()
                }
            }
    }
    
    private func updateDuration(
        from item: AVPlayerItem,
        token: VideoPlaybackOperation.Token,
        expectedPlayer: AVPlayer
    ) {
        guard isCurrentOperation(token, expectedPlayer: expectedPlayer) else { return }

        if item.status == .readyToPlay {
            duration = CMTimeGetSeconds(item.duration)
            durationStatusCancellable?.cancel()
        } else {
            // Wait for readyToPlay
            durationStatusCancellable?.cancel()
            durationStatusCancellable = item.publisher(for: \.status)
                .filter { $0 == .readyToPlay }
                .sink { [weak self, weak item, weak expectedPlayer] _ in
                    Task { @MainActor in
                        guard let self,
                              let expectedPlayer,
                              self.isCurrentOperation(token, expectedPlayer: expectedPlayer),
                              let item else { return }
                        self.duration = CMTimeGetSeconds(item.duration)
                    }
                }
        }
    }

    private func resetPlayerObservers() {
        removeTimeObserver()
        playbackEndedCancellable?.cancel()
        playbackEndedCancellable = nil
        durationStatusCancellable?.cancel()
        durationStatusCancellable = nil
        playerStateCancellable?.cancel()
        playerStateCancellable = nil
    }

    private func removeTimeObserver() {
        if let observer = timeObserver {
            timeObserverOwner?.removeTimeObserver(observer)
            timeObserver = nil
            timeObserverOwner = nil
        }
    }
    
    /// Playback position is written to the video every few seconds while playing, not on every
    /// time tick: each write notifies every view observing the video and dirties the context.
    private static let positionPersistInterval: TimeInterval = 5

    private func persistPlaybackPositionIfNeeded() {
        guard abs(currentTime - lastPersistedPosition) >= Self.positionPersistInterval else { return }
        persistPlaybackPosition()
    }

    private func persistPlaybackPosition() {
        guard let currentVideo else { return }
        lastPersistedPosition = currentTime
        if currentVideo.playbackPosition != currentTime {
            currentVideo.playbackPosition = currentTime
        }
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

    private func observePlaybackState(
        for player: AVPlayer,
        token: VideoPlaybackOperation.Token
    ) {
        playerStateCancellable?.cancel()
        playerStateCancellable = player.publisher(for: \.timeControlStatus)
            .sink { [weak self, weak player] status in
                Task { @MainActor in
                    guard let self,
                          let player,
                          self.isCurrentOperation(token, expectedPlayer: player) else { return }
                    self.isPlaying = (status == .playing)
                }
            }
        isPlaying = player.timeControlStatus == .playing
    }
    
    deinit {
        playbackEndedCancellable?.cancel()
        durationStatusCancellable?.cancel()
        playerStateCancellable?.cancel()
        if let observer = timeObserver {
            timeObserverOwner?.removeTimeObserver(observer)
            timeObserver = nil
            timeObserverOwner = nil
        }
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

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

class VideoPlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoading = false
    @Published var volume: Float = 1.0
    @Published var playbackRate: Float = 1.0
    @Published var availableSubtitles: [Subtitle] = []
    @Published var selectedSubtitle: Subtitle?
    @Published var currentVideo: Video?
    
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    
    func loadVideo(_ video: Video) {
        currentVideo = video
        
        guard let url = video.fileURL else { return }
        
        isLoading = true
        let playerItem = AVPlayerItem(url: url)
        
        // Load subtitles
        if let subtitles = video.subtitles {
            availableSubtitles = Array(subtitles as! Set<Subtitle>)
            // Load subtitle tracks into player item
        }
        
        player = AVPlayer(playerItem: playerItem)
        
        // Restore playback position
        if video.playbackPosition > 0 {
            player?.seek(to: CMTime(seconds: video.playbackPosition, preferredTimescale: 1))
        }
        
        setupTimeObserver()
        setupNotifications()
        
        isLoading = false
    }
    
    func play() {
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
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 1))
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
        // Apply subtitle to player
    }
    
    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
            
            if let duration = self?.player?.currentItem?.duration {
                self?.duration = CMTimeGetSeconds(duration)
            }
            
            // Save playback position periodically
            self?.savePlaybackPosition()
        }
    }
    
    private func setupNotifications() {
        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .sink { [weak self] _ in
                self?.handlePlaybackEnded()
            }
            .store(in: &cancellables)
    }
    
    private func savePlaybackPosition() {
        // Save to Core Data
        currentVideo?.playbackPosition = currentTime
    }
    
    private func handlePlaybackEnded() {
        isPlaying = false
        // Update play count
        if let video = currentVideo {
            video.playCount += 1
            video.lastPlayed = Date()
        }
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }
}
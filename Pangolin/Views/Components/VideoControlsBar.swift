//
//  VideoControlsBar.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//


// Views/Components/VideoControlsBar.swift
import SwiftUI

struct VideoControlsBar: View {
    @ObservedObject var viewModel: VideoPlayerViewModel
    
    var body: some View {
        HStack(spacing: 20) {
            // Play/Pause button
            Button(action: { viewModel.togglePlayPause() }) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            
            // Skip backward
            Button(action: { viewModel.skipBackward() }) {
                Image(systemName: "gobackward.10")
            }
            .buttonStyle(.plain)
            
            // Skip forward
            Button(action: { viewModel.skipForward() }) {
                Image(systemName: "goforward.10")
            }
            .buttonStyle(.plain)
            
            // Time display
            Text(formatTime(viewModel.currentTime))
                .monospacedDigit()
            
            // Progress slider
            Slider(value: Binding(
                get: { viewModel.currentTime },
                set: { viewModel.seek(to: $0) }
            ), in: 0...max(viewModel.duration, 1))
            
            // Duration display
            Text(formatTime(viewModel.duration))
                .monospacedDigit()
            
            // Volume control
            Image(systemName: "speaker.fill")
            Slider(value: $viewModel.volume, in: 0...1)
                .frame(width: 100)
            
            // Playback speed
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button(String(format: "%.2fx", rate)) {
                        viewModel.setPlaybackRate(Float(rate))
                    }
                }
            } label: {
                Text(String(format: "%.2fx", viewModel.playbackRate))
            }
            .frame(width: 60)
            
            // Subtitle menu
            if !viewModel.availableSubtitles.isEmpty {
                Menu {
                    Button("Off") {
                        viewModel.selectSubtitle(nil)
                    }
                    Divider()
                    ForEach(viewModel.availableSubtitles, id: \.id) { subtitle in
                        Button(subtitle.displayName) {
                            viewModel.selectSubtitle(subtitle)
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble")
                }
            }
        }
        .padding(.horizontal)
    }
    
    func formatTime(_ time: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: time) ?? "00:00"
    }
}
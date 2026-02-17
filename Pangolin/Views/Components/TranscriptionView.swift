import SwiftUI

struct TranscriptionView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var timedIndex: TimedTranscript.FlatIndex?
    @State private var activeWordID: UUID?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isTranscriptionRunningForVideo {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = transcriptionErrorMessage {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("Transcription error")
                            .font(.headline)
                    }

                    Text(errorMessage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            content
            Spacer()
        }
        .padding()
        .onAppear {
            loadTimedTranscript()
            updateActiveWord(for: playerViewModel.currentTime)
        }
        .onChange(of: video.id) { _, _ in
            loadTimedTranscript()
        }
        .onChange(of: video.transcriptDateGenerated) { _, _ in
            loadTimedTranscript()
        }
        .onChange(of: playerViewModel.currentTime) { _, newTime in
            updateActiveWord(for: newTime)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let timedIndex {
            ScrollViewReader { proxy in
                ScrollView {
                    TranscriptWordWrapLayout(horizontalSpacing: 6, verticalSpacing: 8) {
                        ForEach(timedIndex.allEntries) { entry in
                            Button {
                                playerViewModel.seek(to: entry.startSeconds)
                            } label: {
                                Text(entry.word.text)
                                    .font(.system(size: 17))
                                    .foregroundStyle(activeWordID == entry.id ? Color.white : Color.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(activeWordID == entry.id ? Color.accentColor : Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: activeWordID) { _, wordID in
                    guard let wordID else { return }
                    withAnimation(.easeInOut(duration: 0.12)) {
                        proxy.scrollTo(wordID, anchor: .center)
                    }
                }
            }
        } else if let loadError {
            ContentUnavailableView(
                "Timed transcript unavailable",
                systemImage: "exclamationmark.bubble",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            ContentUnavailableView(
                "No transcript available",
                systemImage: "doc.text",
                description: Text("Tap 'Transcribe' to create a timestamped transcript.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    private func loadTimedTranscript() {
        guard let url = libraryManager.timedTranscriptURL(for: video) else {
            timedIndex = nil
            loadError = nil
            activeWordID = nil
            return
        }

        do {
            let transcript = try libraryManager.readTimedTranscript(from: url)
            timedIndex = transcript.makeFlatIndex()
            loadError = nil
            updateActiveWord(for: playerViewModel.currentTime)
        } catch {
            timedIndex = nil
            loadError = "Failed to load timed transcript: \(error.localizedDescription)"
            activeWordID = nil
        }
    }

    private func updateActiveWord(for time: TimeInterval) {
        activeWordID = timedIndex?.activeWord(at: time)?.id
    }

    private var transcriptionTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .transcribe)
    }

    private var isTranscriptionRunningForVideo: Bool {
        transcriptionTask?.status == .processing
    }

    private var transcriptionErrorMessage: String? {
        transcriptionTask?.errorMessage
    }
}

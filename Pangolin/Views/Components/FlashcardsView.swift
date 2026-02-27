import SwiftUI

struct FlashcardsView: View {
    @EnvironmentObject private var libraryManager: LibraryManager
    @ObservedObject var video: Video
    @ObservedObject var playerViewModel: VideoPlayerViewModel
    @ObservedObject private var processingQueueManager = ProcessingQueueManager.shared

    @State private var deck: FlashcardDeck?
    @State private var loadError: String?
    @State private var selectedIndex = 0
    @State private var flippedCardIDs = Set<UUID>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
                Spacer(minLength: 0)
            }
            .padding()
        }
        .onAppear {
            loadFlashcards()
        }
        .onChange(of: video.id) { _, _ in
            selectedIndex = 0
            flippedCardIDs.removeAll()
            loadFlashcards()
        }
        .onChange(of: isFlashcardsActive) { _, isActive in
            if !isActive {
                loadFlashcards()
            }
        }
        .onChange(of: flashcardsTask?.status) { _, status in
            if status == .completed {
                loadFlashcards()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if video.transcriptText == nil {
            ContentUnavailableView(
                "Transcript required",
                systemImage: "rectangle.stack.badge.play",
                description: Text("A transcript is required before flashcards can be generated.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if isFlashcardsActive {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("Generating flashcards")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else if let errorMessage = flashcardsErrorMessage {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Flashcards error")
                        .font(.headline)
                }
                Text(errorMessage)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let deck, !deck.cards.isEmpty {
            flashcardsDeckContent(deck)
        } else if let loadError {
            ContentUnavailableView(
                "No flashcards available",
                systemImage: "exclamationmark.bubble",
                description: Text(loadError)
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            ContentUnavailableView(
                "No flashcards yet",
                systemImage: "rectangle.stack.badge.play",
                description: Text("Use the controls inspector to generate flashcards.")
            )
            .frame(maxWidth: .infinity, minHeight: 320)
        }
    }

    @ViewBuilder
    private func flashcardsDeckContent(_ deck: FlashcardDeck) -> some View {
        let cards = deck.cards
        VStack(alignment: .center, spacing: 14) {
            HStack {
                Text(deck.sourceModeUsed == .translation ? "Source: Translation" : "Source: Transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text("\(selectedIndex + 1) / \(cards.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if os(iOS)
            TabView(selection: $selectedIndex) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    FlashcardCardView(
                        card: card,
                        isFlipped: flippedCardIDs.contains(card.id),
                        onToggleFlip: {
                            toggleFlip(for: card.id)
                        },
                        onViewInVideo: {
                            playerViewModel.seek(to: card.startSeconds, in: video)
                        }
                    )
                    .tag(index)
                    .padding(.horizontal, 6)
                }
            }
            .frame(minHeight: 300, maxHeight: 380)
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            #else
            FlashcardCardView(
                card: cards[selectedIndex],
                isFlipped: flippedCardIDs.contains(cards[selectedIndex].id),
                onToggleFlip: {
                    toggleFlip(for: cards[selectedIndex].id)
                },
                onViewInVideo: {
                    playerViewModel.seek(to: cards[selectedIndex].startSeconds, in: video)
                }
            )
            .frame(minHeight: 300, maxHeight: 380)
            .padding(.horizontal, 6)
            .gesture(
                DragGesture(minimumDistance: 16)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < -20 {
                            selectedIndex = min(cards.count - 1, selectedIndex + 1)
                        } else if value.translation.width > 20 {
                            selectedIndex = max(0, selectedIndex - 1)
                        }
                    }
            )
            #endif

            HStack(spacing: 8) {
                Button("Previous") {
                    selectedIndex = max(0, selectedIndex - 1)
                }
                .buttonStyle(.bordered)
                .disabled(selectedIndex == 0)

                Button("Next") {
                    selectedIndex = min(cards.count - 1, selectedIndex + 1)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIndex >= cards.count - 1)
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            let bounded = max(0, min(cards.count - 1, newValue))
            if bounded != newValue {
                selectedIndex = bounded
            }
        }
    }

    private func toggleFlip(for cardID: UUID) {
        if flippedCardIDs.contains(cardID) {
            flippedCardIDs.remove(cardID)
        } else {
            flippedCardIDs.insert(cardID)
        }
    }

    private func loadFlashcards() {
        guard let url = libraryManager.flashcardsURL(for: video),
              FileManager.default.fileExists(atPath: url.path) else {
            deck = nil
            loadError = nil
            selectedIndex = 0
            flippedCardIDs.removeAll()
            return
        }

        do {
            let loadedDeck = try libraryManager.readFlashcardDeck(from: url)
            deck = loadedDeck
            selectedIndex = min(selectedIndex, max(loadedDeck.cards.count - 1, 0))
            loadError = nil
        } catch {
            deck = nil
            loadError = "Failed to load flashcards: \(error.localizedDescription)"
            selectedIndex = 0
            flippedCardIDs.removeAll()
        }
    }

    private var flashcardsTask: ProcessingTask? {
        processingQueueManager.task(for: video, type: .generateFlashcards)
    }

    private var isFlashcardsActive: Bool {
        flashcardsTask?.status.isActive == true
    }

    private var flashcardsErrorMessage: String? {
        flashcardsTask?.errorMessage
    }
}

private struct FlashcardCardView: View {
    let card: Flashcard
    let isFlipped: Bool
    let onToggleFlip: () -> Void
    let onViewInVideo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isFlipped ? "Back" : "Front")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("View in video") {
                    onViewInVideo()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ScrollView {
                Text(isFlipped ? card.back : card.front)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
            }

            Text("Tap card to flip")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            onToggleFlip()
        }
    }
}

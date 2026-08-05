import os
import SwiftUI
import CoreData
import AVFoundation
// MARK: - Video page search

struct VideoPageSearchField: View {
    @ObservedObject var searchModel: VideoPageSearchModel
    var onClear: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search in video", text: $searchModel.query)
                .textFieldStyle(.plain)

            if !searchModel.query.isEmpty {
                Text(searchModel.matchPositionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    searchModel.moveToPreviousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)

                Button {
                    searchModel.moveToNextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)

                Button {
                    searchModel.reset()
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

@MainActor
final class VideoPageSearchModel: ObservableObject {
    enum Direction {
        case previous
        case next
    }

    @Published var query = ""
    @Published private(set) var totalMatches = 0
    @Published private(set) var currentMatchIndex: Int?
    @Published private(set) var navigationRequestID = 0
    private(set) var direction: Direction = .next

    var matchPositionLabel: String {
        guard let currentMatchIndex, totalMatches > 0 else { return "0/0" }
        return "\(currentMatchIndex + 1)/\(totalMatches)"
    }

    func moveToPreviousMatch() {
        guard totalMatches > 0 else { return }
        direction = .previous
        navigationRequestID += 1
    }

    func moveToNextMatch() {
        guard totalMatches > 0 else { return }
        direction = .next
        navigationRequestID += 1
    }

    func setSearchState(totalMatches: Int, currentMatchIndex: Int?) {
        self.totalMatches = totalMatches
        self.currentMatchIndex = currentMatchIndex
    }

    func reset() {
        query = ""
        setSearchState(totalMatches: 0, currentMatchIndex: nil)
    }
}

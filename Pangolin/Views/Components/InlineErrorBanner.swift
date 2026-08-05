import SwiftUI

/// A shared inline error banner used by the content panes (transcript,
/// translation, summary, flashcards). Centralizes the tint, background,
/// corner radius, and optional trailing actions so the panes stop
/// hand-rolling four near-identical copies.
struct InlineErrorBanner: View {
    let title: String
    let message: String
    var systemImage: String = "exclamationmark.triangle"
    var tint: Color = .orange
    var actions: [InlineErrorBannerAction] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)

            if !actions.isEmpty {
                HStack(spacing: 8) {
                    ForEach(actions) { action in
                        if action.isProminent {
                            Button(action.title) {
                                action.handler()
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title) {
                                action.handler()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .padding()
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct InlineErrorBannerAction: Identifiable {
    let id = UUID()
    let title: String
    let isProminent: Bool
    let handler: () -> Void

    init(title: String, isProminent: Bool = false, handler: @escaping () -> Void) {
        self.title = title
        self.isProminent = isProminent
        self.handler = handler
    }
}

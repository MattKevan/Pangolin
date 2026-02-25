import SwiftUI

struct ImportFromURLSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onImport: (URL) async throws -> Void

    @State private var urlText = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import from URL")
                .font(.headline)

            Text("Paste a video URL. Pangolin will download it, import it, and transcribe it as usual.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("https://www.youtube.com/watch?v=...", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .disabled(isSubmitting)

            Text("Imported videos are added to the Downloads folder.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .disabled(isSubmitting)

                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Import")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || normalizedURL == nil)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
    }

    private var normalizedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidateString: String
        if trimmed.contains("://") {
            candidateString = trimmed
        } else {
            candidateString = "https://\(trimmed)"
        }

        guard let url = URL(string: candidateString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }

    private func submit() {
        guard let url = normalizedURL else {
            errorMessage = "Enter a valid http(s) URL."
            return
        }

        errorMessage = nil
        isSubmitting = true

        Task {
            do {
                try await onImport(url)
                await MainActor.run {
                    isSubmitting = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSubmitting = false
                }
            }
        }
    }
}

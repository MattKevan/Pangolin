//
//  ActivityToolbarButton.swift
//  Pangolin
//

import SwiftUI

/// What the toolbar activity widget shows, decided from the queue and transfer counts.
enum ActivityIndicatorPolicy {
    enum Style: Equatable {
        /// Work is running and its overall progress is known.
        case progress(Double)
        /// Work is running but progress is not known yet.
        case spinner
        /// Nothing is running, but something failed.
        case warning
    }

    struct Presentation: Equatable {
        let style: Style
        let badgeCount: Int
    }

    /// Returns nil when there is nothing to show, so the widget disappears.
    static func presentation(
        activeCount: Int,
        failedTaskCount: Int,
        transferIssueCount: Int,
        progress: Double?
    ) -> Presentation? {
        guard activeCount > 0 || failedTaskCount > 0 || transferIssueCount > 0 else { return nil }

        let style: Style
        if let progress {
            style = .progress(min(max(progress, 0), 1))
        } else if activeCount > 0 {
            style = .spinner
        } else {
            style = .warning
        }

        // Problems take over the badge; otherwise it counts the work beyond the first item.
        let issues = failedTaskCount + transferIssueCount
        let badge = issues > 0 ? issues : max(0, activeCount - 1)
        return Presentation(style: style, badgeCount: badge)
    }
}

/// The toolbar button for background work: a progress ring or spinner, a count badge, and a popover.
struct ActivityToolbarButton<PopoverContent: View>: View {
    let presentation: ActivityIndicatorPolicy.Presentation
    let accessibilityValue: String
    @Binding var isPresented: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                indicator
                    .frame(width: 18, height: 18)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)

                if presentation.badgeCount > 0 {
                    Text(min(presentation.badgeCount, 99), format: .number)
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Color.red, in: Capsule())
                        .offset(x: 6, y: -4)
                        .accessibilityHidden(true)
                }
            }
            .frame(minWidth: 24, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Background tasks")
        .accessibilityValue(accessibilityValue)
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            popoverContent()
                .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch presentation.style {
        case .progress(let value):
            ZStack {
                Circle()
                    .stroke(.secondary.opacity(0.3), lineWidth: 2.4)
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(1.5)
        case .spinner:
            ProgressView()
                .controlSize(.small)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

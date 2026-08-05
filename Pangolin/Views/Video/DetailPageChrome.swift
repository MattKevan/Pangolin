import os
import SwiftUI
import CoreData
import AVFoundation
// MARK: - Video page chrome

struct VideoPageTabPicker: View {
    @Binding var selectedTab: InspectorTab

    var body: some View {
        Picker("Section", selection: $selectedTab) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(6)
        .frame(maxWidth: 340, alignment: .leading)
        .pangolinGlassRoundedRect(cornerRadius: 22, interactive: true)
    }
}

struct VideoPageNavigationBar: View {
    let previousTitle: String?
    let nextTitle: String?
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            if let previousTitle {
                navigationButton(title: previousTitle, systemImage: "chevron.left", trailingIcon: false, action: onPrevious)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }

            Spacer()

            if let nextTitle {
                navigationButton(title: nextTitle, systemImage: "chevron.right", trailingIcon: true, action: onNext)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }
        }
    }

    private func navigationButton(
        title: String,
        systemImage: String,
        trailingIcon: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if !trailingIcon {
                    Image(systemName: systemImage)
                }

                Text(title)
                    .font(.headline.weight(.semibold))

                if trailingIcon {
                    Image(systemName: systemImage)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(minWidth: 148)
        }
        .pangolinGlassButton()
        .buttonBorderShape(.capsule)
    }
}

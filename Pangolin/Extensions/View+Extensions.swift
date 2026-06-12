//
//  View+Extensions.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

// Extensions/View+Extensions.swift
import SwiftUI

extension View {
    func pangolinAlert<T: LocalizedError>(error: Binding<T?>) -> some View {
        self.alert(
            "Error",
            isPresented: .constant(error.wrappedValue != nil),
            presenting: error.wrappedValue
        ) { _ in
            Button("OK") {
                error.wrappedValue = nil
            }
        } message: { err in
            Text(err.errorDescription ?? "An unknown error occurred")
        }
    }
}

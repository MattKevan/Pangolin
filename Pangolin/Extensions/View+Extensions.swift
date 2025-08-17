//
//  View+Extensions.swift
//  Pangolin
//
//  Created by Matt Kevan on 16/08/2025.
//

// Extensions/View+Extensions.swift
import SwiftUI  // ← Add this import
import Foundation

extension View {
    func pangolinAlert<T: LocalizedError>(error: Binding<T?>) -> some View {
        self.alert(isPresented: .constant(error.wrappedValue != nil)) {
            Alert(
                title: Text("Error"),
                message: Text(error.wrappedValue?.errorDescription ?? "An unknown error occurred"),
                dismissButton: .default(Text("OK")) {
                    error.wrappedValue = nil
                }
            )
        }
    }
}

import SwiftUI

extension View {
    /// Liquid Glass (macOS 26), ellers matt glass.
    @ViewBuilder func glass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

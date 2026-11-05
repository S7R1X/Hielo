//
//  HieloBrand.swift
//  Hielo
//

import SwiftUI

/// Hielo's own colours and marks: the blue of the app icon, the Illimani as a watermark
/// and the Bolivian flag.
enum HieloBrand {
    /// The blue of the app icon (#2C4899).
    static let blue = Color(red: 44 / 255, green: 72 / 255, blue: 153 / 255)
}

/// A soft wash of the icon's blue behind a settings pane, with the Illimani as a
/// watermark in the lower right corner.
struct HieloBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Light enough that the panes' own sections and text keep their contrast.
            LinearGradient(
                colors: [
                    HieloBrand.blue.opacity(colorScheme == .dark ? 0.38 : 0.18),
                    HieloBrand.blue.opacity(colorScheme == .dark ? 0.16 : 0.08),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(.illimaniStroke)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 420)
                .foregroundStyle(colorScheme == .dark ? Color.white : HieloBrand.blue)
                .opacity(colorScheme == .dark ? 0.10 : 0.12)
                .padding(.trailing, -50)
                .padding(.bottom, -40)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// The flag of Bolivia, drawn rather than loaded: three bands, red, yellow and green.
struct BoliviaFlag: View {
    var width: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            Color(red: 213 / 255, green: 43 / 255, blue: 30 / 255)
            Color(red: 249 / 255, green: 227 / 255, blue: 0)
            Color(red: 0, green: 121 / 255, blue: 52 / 255)
        }
        .frame(width: width, height: width * 2 / 3)
        .clipShape(RoundedRectangle(cornerRadius: width / 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: width / 9, style: .continuous)
                .strokeBorder(.black.opacity(0.25), lineWidth: 0.5)
        }
        .accessibilityLabel(Text("Flag of Bolivia"))
    }
}


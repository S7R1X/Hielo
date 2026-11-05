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
            // Drawn as vectors, so it stays sharp at this size (the menu bar glyph is a
            // 40 px bitmap and pixelated when scaled up).
            IllimaniMark()
                .frame(width: 420, height: 420)
                .foregroundStyle(colorScheme == .dark ? Color.white : HieloBrand.blue)
                .opacity(colorScheme == .dark ? 0.10 : 0.12)
                .padding(.trailing, -50)
                .padding(.bottom, -40)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// The Illimani of the app icon as vector strokes: the silhouette and the snow line, in the
/// same proportions as the menu bar glyph (a 40 × 40 design), scaled to the view's size.
struct IllimaniMark: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width, geometry.size.height) / 40
            ZStack {
                IllimaniSilhouette()
                    .stroke(style: StrokeStyle(lineWidth: 3 * scale, lineCap: .round, lineJoin: .round))
                IllimaniSnowLine()
                    .stroke(style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round, lineJoin: .round))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct IllimaniSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 40
        let points: [CGPoint] = [
            CGPoint(x: 4, y: 33), CGPoint(x: 11, y: 20), CGPoint(x: 14.5, y: 14), CGPoint(x: 17.5, y: 17),
            CGPoint(x: 22, y: 9), CGPoint(x: 25, y: 12.5), CGPoint(x: 29, y: 5), CGPoint(x: 32.5, y: 15),
            CGPoint(x: 36, y: 33),
        ]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * s, y: rect.minY + $0.y * s) })
        path.closeSubpath()
        return path
    }
}

private struct IllimaniSnowLine: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 40
        let points: [CGPoint] = [
            CGPoint(x: 9.5, y: 23), CGPoint(x: 13, y: 20), CGPoint(x: 16, y: 23), CGPoint(x: 19.5, y: 19.5),
            CGPoint(x: 23, y: 23), CGPoint(x: 27, y: 18), CGPoint(x: 30.5, y: 22), CGPoint(x: 33.5, y: 20),
        ]
        var path = Path()
        path.addLines(points.map { CGPoint(x: rect.minX + $0.x * s, y: rect.minY + $0.y * s) })
        return path
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


// Copyright (C) 2026 Ryan Lefkowitz
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI

/// A small landscape drawn in the view's own coordinate space. Phase is supplied in radians.
struct DuskHorizon: View {
    let phase: Double
    let seed: UInt64
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let night = colorScheme == .dark
        Canvas { context, size in
            HorizonDiagnostics.draw()
            let width = size.width
            let height = size.height
            let sky =
                night
                ? [
                    Color(red: 0.13, green: 0.14, blue: 0.23),
                    Color(red: 0.46, green: 0.41, blue: 0.48),
                ]
                : [
                    Color(red: 0.58, green: 0.52, blue: 0.53),
                    Color(red: 0.91, green: 0.73, blue: 0.61),
                ]
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: sky), startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: width * 0.18, y: height * 0.77)))

            let offset = Double(seed % 997) / 997 * 2 * .pi
            let drift = sin(phase + offset)
            let diameter = min(height * 0.74, width * 0.33)
            let sun = CGRect(
                x: width * (0.64 + 0.016 * drift) - diameter / 2,
                y: height * (0.52 + 0.018 * cos(phase + offset)) - diameter / 2,
                width: diameter, height: diameter)
            let light = Color(red: 1, green: 0.84, blue: 0.61)
            let halo = sun.insetBy(dx: -diameter * 0.15, dy: -diameter * 0.15)
            context.stroke(
                Path(ellipseIn: halo), with: .color(light.opacity(0.32)), lineWidth: 0.65)
            context.fill(Path(ellipseIn: sun), with: .color(light))

            func point(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: x * width, y: y * height)
            }
            var ridge = Path()
            ridge.move(to: point(0, 0.50))
            ridge.addCurve(
                to: point(0.51, 0.69), control1: point(0.19, 0.44 + drift * 0.025),
                control2: point(0.32, 0.79))
            ridge.addCurve(
                to: point(1, 0.51), control1: point(0.68, 0.66),
                control2: point(0.83, 0.36 - drift * 0.025))
            ridge.addLine(to: point(1, 1))
            ridge.addLine(to: point(0, 1))
            ridge.closeSubpath()
            let far =
                night
                ? Color(red: 0.34, green: 0.32, blue: 0.41)
                : Color(red: 0.42, green: 0.41, blue: 0.49)
            context.fill(ridge, with: .color(far))

            var foreground = Path()
            foreground.move(to: point(0, 0.83))
            foreground.addCurve(
                to: point(0.54, 0.64), control1: point(0.20, 0.89 - drift * 0.035),
                control2: point(0.37, 0.60))
            foreground.addCurve(
                to: point(1, 0.79), control1: point(0.71, 0.66),
                control2: point(0.80, 0.88 + drift * 0.025))
            let near =
                night
                ? Color(red: 0.16, green: 0.18, blue: 0.27)
                : Color(red: 0.20, green: 0.24, blue: 0.33)
            var land = foreground
            land.addLine(to: point(1, 1))
            land.addLine(to: point(0, 1))
            land.closeSubpath()
            context.fill(land, with: .color(near))
            for inset in [0.075, 0.15] {
                let contour = foreground.offsetBy(dx: 0, dy: height * inset)
                context.stroke(contour, with: .color(light.opacity(0.18)), lineWidth: 0.65)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

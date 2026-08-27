import SwiftUI

/// Animated splash shown after the static system launch screen.
struct SplashView: View {
    var onFinished: () -> Void

    @State private var logoScale: CGFloat = 0.72
    @State private var logoOpacity: Double = 0
    @State private var titleOpacity: Double = 0
    @State private var titleOffset: CGFloat = 12
    @State private var needleProgress: CGFloat = 0
    @State private var pulse = false
    @State private var roadPhase: CGFloat = 0
    @State private var gpsBars = 0
    @State private var dismissOpacity: Double = 1

    private let mint = Color(hex: 0x00E5A0)
    private let blue = Color(hex: 0x00B4FF)
    private let deep = Color(hex: 0x101014)

    var body: some View {
        ZStack {
            deep.ignoresSafeArea()

            Image("SplashBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .opacity(0.9)

            // Soft animated glow behind the mark
            Circle()
                .fill(
                    RadialGradient(
                        colors: [mint.opacity(pulse ? 0.28 : 0.12), blue.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 180
                    )
                )
                .frame(width: 360, height: 360)
                .blur(radius: 8)
                .offset(y: -36)

            VStack(spacing: 28) {
                Spacer(minLength: 0)

                ZStack {
                    SplashSpeedometer(progress: needleProgress, mint: mint, blue: blue)
                        .frame(width: 220, height: 220)
                        .opacity(logoOpacity)

                    Image("AppLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 108, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: mint.opacity(0.35), radius: pulse ? 22 : 10, y: 4)
                        .scaleEffect(logoScale)
                        .opacity(logoOpacity)
                }

                VStack(spacing: 8) {
                    Text("MotoTripTracker")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text("Track every ride")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(mint.opacity(0.9))
                }
                .opacity(titleOpacity)
                .offset(y: titleOffset)

                SplashGPSBars(filled: gpsBars, tint: mint)
                    .opacity(titleOpacity)

                Spacer(minLength: 0)

                SplashRoad(phase: roadPhase, mint: mint, blue: blue)
                    .frame(height: 56)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 48)
                    .opacity(titleOpacity)
            }
            .padding(.horizontal, 24)
        }
        .opacity(dismissOpacity)
        .onAppear(perform: runAnimation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MotoTripTracker")
    }

    private func runAnimation() {
        withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) {
            logoScale = 1
            logoOpacity = 1
        }
        withAnimation(.easeOut(duration: 1.15)) {
            needleProgress = 1
        }
        withAnimation(.easeOut(duration: 0.55).delay(0.25)) {
            titleOpacity = 1
            titleOffset = 0
        }
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            pulse = true
        }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            roadPhase = 1
        }

        // Animate GPS bars filling 0→4
        for step in 1...4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 + Double(step) * 0.18) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    gpsBars = step
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.15) {
            withAnimation(.easeInOut(duration: 0.45)) {
                dismissOpacity = 0
                logoScale = 1.08
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                onFinished()
            }
        }
    }
}

private struct SplashSpeedometer: View {
    var progress: CGFloat
    var mint: Color
    var blue: Color

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2 + 8)
            let radius = min(size.width, size.height) * 0.42
            let start = Angle.degrees(150)
            let total = Angle.degrees(240)

            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: start, endAngle: start + total, clockwise: false)
            context.stroke(track, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 10, lineCap: .round))

            var arc = Path()
            arc.addArc(
                center: center,
                radius: radius,
                startAngle: start,
                endAngle: start + Angle(degrees: 240 * Double(progress)),
                clockwise: false
            )
            context.stroke(
                arc,
                with: .linearGradient(
                    Gradient(colors: [mint, blue]),
                    startPoint: CGPoint(x: 0, y: size.height),
                    endPoint: CGPoint(x: size.width, y: 0)
                ),
                style: StrokeStyle(lineWidth: 10, lineCap: .round)
            )

            let needleAngle = start + Angle(degrees: 240 * Double(progress))
            let needleLength = radius - 18
            let tip = CGPoint(
                x: center.x + CGFloat(cos(needleAngle.radians)) * needleLength,
                y: center.y + CGFloat(sin(needleAngle.radians)) * needleLength
            )
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            context.stroke(needle, with: .color(mint), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            let hub = Path(ellipseIn: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            context.fill(hub, with: .color(mint))
        }
    }
}

private struct SplashGPSBars: View {
    var filled: Int
    var tint: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? tint : tint.opacity(0.2))
                    .frame(width: 5, height: 8 + CGFloat(index) * 5)
            }
        }
        .frame(height: 26, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

private struct SplashRoad: View {
    var phase: CGFloat
    var mint: Color
    var blue: Color

    var body: some View {
        Canvas { context, size in
            let midY = size.height * 0.55
            var road = Path()
            road.move(to: CGPoint(x: 0, y: midY))
            road.addQuadCurve(
                to: CGPoint(x: size.width, y: midY),
                control: CGPoint(x: size.width * 0.5, y: midY - 18)
            )
            context.stroke(road, with: .color(.white.opacity(0.12)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

            let dashCount = 7
            for i in 0..<dashCount {
                let t = (CGFloat(i) + phase).truncatingRemainder(dividingBy: CGFloat(dashCount)) / CGFloat(dashCount)
                let x = t * size.width
                let y = midY - 18 * 4 * t * (1 - t)
                let rect = CGRect(x: x - 10, y: y - 1.5, width: 20, height: 3)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(i % 2 == 0 ? mint.opacity(0.85) : blue.opacity(0.75))
                )
            }
        }
    }
}

#Preview {
    SplashView(onFinished: {})
}

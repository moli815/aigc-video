import SwiftUI

/// C: silver-blue particles gather, rest, then unfold. Status remains task-driven.
struct ImageWaitingRow: View {
    let state: ImageWaitState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var started = Date()

    private var enabled: Bool { HostedAccount.behaviorBool("imageWaitParticles", default: true) }
    private var isStill: Bool { reduceMotion || lowPower }
    private var particleCount: Int { min(240, max(60, HostedAccount.behaviorInt("imageWaitParticleCount", default: 200))) }
    private var cycle: Double { HostedAccount.behaviorDouble("imageWaitCycle", default: 5.8) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12))
                Text(state.text).font(.system(size: 13))
            }
            .foregroundStyle(.secondary)
            if enabled {
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                                        paused: isStill || !visible || scenePhase != .active)) { timeline in
                    Canvas { context, size in
                        let elapsed = timeline.date.timeIntervalSince(started)
                        let center = CGPoint(x: size.width * 0.5, y: size.height * 0.51)
                        let glow = Path(ellipseIn: CGRect(x: center.x - 90, y: center.y - 90,
                                                         width: 180, height: 180))
                        context.fill(glow, with: .radialGradient(
                            Gradient(colors: [Color(red: 0.60, green: 0.71, blue: 0.88).opacity(0.19), .clear]),
                            center: center, startRadius: 0, endRadius: 90))
                        let palette: [Color] = colorScheme == .dark
                            ? [Color(red: 0.80, green: 0.86, blue: 0.96), Color(red: 0.63, green: 0.75, blue: 0.93),
                               Color(red: 0.84, green: 0.81, blue: 0.93), Color(red: 0.71, green: 0.81, blue: 0.92), .white]
                            : [Color(red: 0.32, green: 0.45, blue: 0.63), Color(red: 0.37, green: 0.50, blue: 0.67),
                               Color(red: 0.52, green: 0.46, blue: 0.65), Color(red: 0.36, green: 0.54, blue: 0.62), .gray]
                        for index in 0..<particleCount {
                            let p = ImageWaitMotion.frame(index: index, elapsed: elapsed,
                                width: size.width, height: size.height, cycle: cycle, still: isStill)
                            if !isStill {
                                let previous = ImageWaitMotion.frame(index: index, elapsed: max(0, elapsed - 0.06),
                                    width: size.width, height: size.height, cycle: cycle)
                                var trail = Path()
                                trail.move(to: CGPoint(x: previous.x, y: previous.y))
                                trail.addLine(to: CGPoint(x: p.x, y: p.y))
                                context.stroke(trail, with: .color(palette[p.tint].opacity(p.opacity * 0.25)), lineWidth: 0.7)
                            }
                            context.fill(Path(ellipseIn: CGRect(x: p.x - p.radius, y: p.y - p.radius,
                                                                width: p.radius * 2, height: p.radius * 2)),
                                         with: .color(palette[p.tint].opacity(p.opacity)))
                        }
                    }
                    .frame(height: 210)
                    .background(colorScheme == .dark ? Color(red: 0.09, green: 0.10, blue: 0.13)
                                                    : Color(red: 0.94, green: 0.95, blue: 0.97))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.text)
        .onAppear { started = Date(); visible = true }
        .onDisappear { visible = false }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

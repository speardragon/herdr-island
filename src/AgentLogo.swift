import SwiftUI
import AppKit

// Provider marks live in assets/logos/<agent-kind>.png next to bin/.
// Agents without a mark get a tinted monogram.

enum LogoStore {
    static let directory: URL = {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("assets/logos")
    }()

    private static var cache: [String: NSImage?] = [:]

    static func image(for kind: String) -> NSImage? {
        if let cached = cache[kind] { return cached }
        let image = NSImage(contentsOf: directory.appendingPathComponent("\(kind).png"))
        cache[kind] = image
        return image
    }
}

struct AgentLogo: View {
    let kind: String
    var size: CGFloat = 26
    var status: AgentStatus? = nil

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            mark
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            if let status = status {
                StatusDot(status: status, size: max(7, size * 0.3))
                    .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
    }

    @ViewBuilder private var mark: some View {
        if let image = LogoStore.image(for: kind) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.17)
        } else {
            Text(Agent.providerName(kind).prefix(1))
                .font(.system(size: size * 0.48, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
        }
    }
}

struct StatusDot: View {
    let status: AgentStatus
    var size: CGFloat = 8
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Theme.color(for: status))
            .frame(width: size, height: size)
            .shadow(color: Theme.color(for: status).opacity(0.8), radius: pulse ? 5 : 2)
            .scaleEffect(pulse ? 1.0 : 0.82)
            .onAppear {
                // A repeating animation re-lays out the whole island every frame, so only a
                // waiting agent earns one; agents are working nearly all the time.
                guard status == .blocked else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

import SwiftUI

// A soft, breathing light along the island's edge: red while an agent is blocked,
// green when one is done. Drawn as stacked blurred strokes so it reads as light, not a line.

struct GlowBorder<S: Shape>: View {
    let shape: S
    let color: Color
    let intensity: Double
    @State private var breathe = false

    var body: some View {
        ZStack {
            shape.stroke(color.opacity(0.55 * intensity), lineWidth: 8).blur(radius: 14)
            shape.stroke(color.opacity(0.7 * intensity), lineWidth: 3).blur(radius: 5)
            shape.stroke(color.opacity(0.9 * intensity), lineWidth: 1.1)
        }
        .opacity(breathe ? 1 : 0.4)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

extension Color {
    /// "FF453A" → Color; config values are validated, so this never sees bad input in practice.
    init(hex: String) {
        let value = UInt64(hex, radix: 16) ?? 0
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// Color → "RRGGBB", for writing a picked color back to config.toml.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}

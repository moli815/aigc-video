import Foundation

/// Deterministic presentation only; a cycle never represents provider progress.
enum ImageWaitMotion {
    struct Particle {
        let x: Double
        let y: Double
        let radius: Double
        let opacity: Double
        let tint: Int
    }
    static func frame(index: Int, elapsed: Double, width: Double, height: Double,
                      cycle: Double = 5.8, still: Bool = false) -> Particle {
        let w = width.isFinite ? max(0, width) : 0
        let h = height.isFinite ? max(0, height) : 0
        let duration = cycle.isFinite ? min(12, max(3, cycle)) : 5.8
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        let q = still ? 0.39 : (time / duration + random(index, 5) * 0.075).truncatingRemainder(dividingBy: 1)
        let gather = ease(q / 0.43), spread = ease((q - 0.56) / 0.44)
        let distance = 0.28 + random(index, 2) * 0.42
        let core = 0.018 + random(index, 3) * 0.072
        let radius = min(w, h) * (distance * (1 - gather) * (1 - spread)
                                  + core * gather * (1 - spread) + (distance + 0.04) * spread)
        let angle = random(index, 1) * .pi * 2 + 0.28 * gather + 0.24 * spread
        let fade = still ? 0.8 : clamp(q / 0.10) * clamp((1 - q) / 0.16)
        return Particle(x: w * 0.5 + cos(angle) * radius,
                        y: h * 0.51 + sin(angle) * radius * 0.78,
                        radius: (0.5 + random(index, 4) * 1.2) * max(0.8, min(w, h) / 370),
                        opacity: (0.54 + random(index, 6) * 0.25) * fade, tint: abs(index % 5))
    }
    private static func random(_ index: Int, _ salt: Int) -> Double {
        let value = sin(Double(index + 1) * 127.1 + Double(salt) * 311.7) * 43758.5453
        return value - floor(value)
    }
    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func ease(_ x: Double) -> Double {
        let t = clamp(x)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

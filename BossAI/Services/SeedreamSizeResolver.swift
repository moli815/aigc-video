import Foundation

/// Compiles the app's canvas intent into Seedream's native `size` parameter.
/// The hosted API has its own server-side adapter; this resolver is for direct BYOK calls.
enum SeedreamSizeResolver {
    private static let presets: [String: [String: String]] = [
        "1K": [
            "1:1": "1024x1024", "4:3": "1152x864", "3:4": "864x1152",
            "16:9": "1424x800", "9:16": "800x1424", "3:2": "1248x832",
            "2:3": "832x1248", "21:9": "1568x672",
        ],
        "1.5K": [
            "1:1": "1536x1536", "4:3": "1792x1344", "3:4": "1344x1792",
            "16:9": "2048x1152", "9:16": "1152x2048", "3:2": "1872x1248",
            "2:3": "1248x1872", "21:9": "2352x1008",
        ],
        "2K": [
            "1:1": "2048x2048", "4:3": "2368x1776", "3:4": "1776x2368",
            "16:9": "2816x1584", "9:16": "1584x2816", "3:2": "2496x1664",
            "2:3": "1664x2496", "21:9": "3136x1344",
        ],
    ]
    private static let pixelTargets: [String: Double] = [
        "1K": 1_048_576,
        "1.5K": 2_359_296,
        "2K": 4_194_304,
    ]

    /// Returns a bounded native pixel size, or nil when the requested canvas cannot fit
    /// the app's image memory/provider limits. No aspect ratio is silently substituted.
    static func resolve(aspectRatio raw: String, tier rawTier: String = "2K") -> String? {
        guard let (ratio, key) = parseRatio(raw) else { return nil }
        let tier = pixelTargets.keys.first { $0.caseInsensitiveCompare(rawTier) == .orderedSame } ?? "2K"
        if let preset = presets[tier]?[key] {
            return resolveExplicit(preset)
        }

        let pixels = pixelTargets[tier] ?? pixelTargets["2K"]!
        let width = snapToEight(sqrt(pixels * ratio))
        let height = snapToEight(sqrt(pixels / ratio))
        return ImageGeometry.clampedSize(width: width, height: height)
    }

    /// Validates and bounds an explicit WxH value using the same geometry limits as the app.
    static func resolveExplicit(_ raw: String) -> String? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Int(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return ImageGeometry.clampedSize(width: width, height: height)
    }

    private static func parseRatio(_ raw: String) -> (Double, String)? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "×", with: ":")
            .replacingOccurrences(of: "x", with: ":")
            .replacingOccurrences(of: "X", with: ":")
            .replacingOccurrences(of: "*", with: ":")
        let parts = normalized.split(separator: ":")
        guard parts.count == 2,
              let width = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let height = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let ratio = width / height
        guard ratio >= 1.0 / 16.0, ratio <= 16 else { return nil }
        return (ratio, "\(format(width)):\(format(height))")
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func snapToEight(_ value: Double) -> Int {
        Int((value / 8).rounded()) * 8
    }
}

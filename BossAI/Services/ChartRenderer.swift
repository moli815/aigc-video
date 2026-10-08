import Foundation
import SwiftUI
import Charts

/// render_chart 工具的输入契约（模型输出 JSON → 本地渲染）
struct ChartSpec: Sendable {
    enum ChartType: String, Sendable { case bar, line, pie }
    let type: ChartType
    let title: String
    let labels: [String]
    let values: [Double]
    let unit: String
    let sourceNote: String

    static func parse(_ arguments: String) -> ChartSpec? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        let typeRaw = (obj["type"] as? String)?.lowercased() ?? "bar"
        guard let type = ChartType(rawValue: typeRaw) else { return nil }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let labels = ((obj["labels"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
        let values = ((obj["values"] as? [Any]) ?? []).compactMap { value -> Double? in
            if let d = value as? Double, d.isFinite { return d }
            if let i = value as? Int { return Double(i) }
            if let s = value as? String, let d = Double(s), d.isFinite { return d }
            return nil
        }
        guard labels.count == values.count, !labels.isEmpty, labels.count <= 12 else { return nil }
        let unit = (obj["unit"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let note = (obj["source_note"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return ChartSpec(type: type, title: String(title.prefix(60)), labels: labels, values: values,
                         unit: String(unit.prefix(12)), sourceNote: String(note.prefix(80)))
    }
}

/// Swift Charts 渲染视图（用于 ImageRenderer 成图）
struct StatChartView: View {
    let spec: ChartSpec

    private var shortLabels: [String] {
        spec.labels.map { $0.count > 8 ? String($0.prefix(7)) + "…" : $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(spec.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.black)
            Chart {
                chartContent
            }
            .chartLegend(spec.type == .pie ? .visible : .hidden)
            .frame(height: 300)
            if !spec.sourceNote.isEmpty {
                Text("数据来源：\(spec.sourceNote)")
                    .font(.system(size: 13))
                    .foregroundStyle(.gray)
            }
        }
        .padding(20)
        .frame(width: 680, alignment: .leading)
        .background(Color.white)
    }

    @ChartContentBuilder private var chartContent: some ChartContent {
        let pairs = Array(zip(shortLabels, spec.values).enumerated())
        switch spec.type {
        case .bar:
            ForEach(pairs, id: \.offset) { _, pair in
                BarMark(x: .value("项目", pair.0), y: .value("数值", pair.1))
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .top) {
                        Text(unitText(pair.1)).font(.system(size: 11)).foregroundStyle(.gray)
                    }
            }
        case .line:
            ForEach(pairs, id: \.offset) { _, pair in
                LineMark(x: .value("项目", pair.0), y: .value("数值", pair.1))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.catmullRom)
                PointMark(x: .value("项目", pair.0), y: .value("数值", pair.1))
                    .foregroundStyle(Color.accentColor)
                    .annotation(position: .top) {
                        Text(unitText(pair.1)).font(.system(size: 11)).foregroundStyle(.gray)
                    }
            }
        case .pie:
            ForEach(pairs, id: \.offset) { _, pair in
                SectorMark(angle: .value("数值", pair.1), innerRadius: .ratio(0.55), angularInset: 1.5)
                    .foregroundStyle(by: .value("项目", pair.0))
                    .cornerRadius(4)
            }
        }
    }

    private func unitText(_ value: Double) -> String {
        let number = value >= 10_000 ? String(format: "%.1f万", value / 10_000) : (value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value))
        return spec.unit.isEmpty ? number : "\(number)\(spec.unit)"
    }
}

/// 渲染成 UIImage（主线程调用；失败返回 nil 时调用方回执让模型改用表格）
enum ChartRenderer {
    @MainActor
    static func render(_ spec: ChartSpec) -> UIImage? {
        let view = StatChartView(spec: spec)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }
}

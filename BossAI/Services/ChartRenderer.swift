import Foundation
import SwiftUI
import Charts

//
//  ChartRenderer.swift
//  BossAI（中防AI iPad App）— Services 层
//
//  文件职责：实现 render_chart 工具链——接收模型输出的 JSON 图表描述，
//  本地解析校验后用 Swift Charts 渲染成 UIImage 插入对话。
//
//  在整个 App 中的角色：让模型"会画图"。模型只产出结构化 JSON，真正的绘图
//  完全在本地完成，保证样式可控且不泄露用户数据。
//
//  关键设计决策：
//  - 输入契约（ChartSpec）逐字段严格校验：类型合法、标题非空、labels/values
//    等长且 ≤12 项、数值必须有限（拒绝 NaN/Inf），任何一项不过就整体拒绝。
//  - 文本长度截断（标题 60 / 单位 12 / 来源 80 / 标签 8），防模型输出超长串撑爆布局。
//  - 渲染失败返回 nil，调用方回执让模型改用 Markdown 表格兜底展示。
//
//  防呆/安全冗余理由：
//  - 模型输出不可信，所以 parse 是"白名单式"容错：多余字段忽略、非法值拒绝。
//  - 数值格式化时先判 finite，防止 NaN 破坏渲染。
//
/// render_chart 工具的输入契约（模型输出 JSON → 本地渲染）
struct ChartSpec: Sendable {
    /// 支持的图表类型：柱状 / 折线 / 饼图
    enum ChartType: String, Sendable { case bar, line, pie }
    /// 图表类型
    let type: ChartType
    /// 图表标题
    let title: String
    /// 各数据项标签
    let labels: [String]
    /// 与 labels 一一对应的数值
    let values: [Double]
    /// 数值单位（可为空）
    let unit: String
    /// 数据来源说明（可为空）
    let sourceNote: String

    /// 从模型输出的 JSON 字符串解析并校验出 ChartSpec。
    /// - Parameter arguments: 模型输出的工具参数 JSON 文本
    /// - Returns: 校验通过返回 ChartSpec；任何字段非法（类型未知、标题为空、
    ///   labels/values 不等长、超过 12 项等）返回 nil
    static func parse(_ arguments: String) -> ChartSpec? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any] else { return nil }
        // 类型字段缺省按柱状图处理；小写化兼容模型输出 "Bar"/"BAR" 等写法
        let typeRaw = (obj["type"] as? String)?.lowercased() ?? "bar"
        guard let type = ChartType(rawValue: typeRaw) else { return nil }
        let title = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // 标题是图表的必需品，空白标题直接拒绝
        guard !title.isEmpty else { return nil }
        let labels = ((obj["labels"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
        // 数值容错解析：Double/Int/数字字符串三种来源都接受，NaN/Inf 一律丢弃
        let values = ((obj["values"] as? [Any]) ?? []).compactMap { value -> Double? in
            if let d = value as? Double, d.isFinite { return d }
            if let i = value as? Int { return Double(i) }
            if let s = value as? String, let d = Double(s), d.isFinite { return d }
            return nil
        }
        // 数量约束：标签数值等长、非空且 ≤12 项（再多图例/布局就放不下了）
        guard labels.count == values.count, !labels.isEmpty, labels.count <= 12 else { return nil }
        let unit = (obj["unit"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let note = (obj["source_note"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        // 长度截断是最后一道防呆：模型若输出超长文本也不会破坏成图布局
        return ChartSpec(type: type, title: String(title.prefix(60)), labels: labels, values: values,
                         unit: String(unit.prefix(12)), sourceNote: String(note.prefix(80)))
    }
}

/// Swift Charts 渲染视图（用于 ImageRenderer 成图）
struct StatChartView: View {
    /// 要渲染的图表规格
    let spec: ChartSpec

    /// 标签缩略：超过 8 字符的标签截到 7 字 + "…"，防止 X 轴标签互相挤压
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

    /// 按图表类型构建对应的 Mark 序列（柱状/折线/饼图三分支）
    @ChartContentBuilder private var chartContent: some ChartContent {
        // 用 zip 把标签与数值配对，以枚举下标作稳定 id
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

    /// 把数值格式化成易读文本：≥1 万转"万"单位；整数不带小数；其余保留 1 位小数；
    /// 再拼接图表单位（若已设置）
    private func unitText(_ value: Double) -> String {
        let number = value >= 10_000 ? String(format: "%.1f万", value / 10_000) : (value.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(value)) : String(format: "%.1f", value))
        return spec.unit.isEmpty ? number : "\(number)\(spec.unit)"
    }
}

/// 渲染成 UIImage（主线程调用；失败返回 nil 时调用方回执让模型改用表格）
enum ChartRenderer {
    /// 用 SwiftUI 的 ImageRenderer 把图表视图画成 2x 位图。
    /// - Parameter spec: 已校验通过的图表规格
    /// - Returns: 成功返回 UIImage；渲染失败返回 nil，调用方应回执让模型改用表格兜底
    @MainActor
    static func render(_ spec: ChartSpec) -> UIImage? {
        let view = StatChartView(spec: spec)
        let renderer = ImageRenderer(content: view)
        // 2x 缩放：保证在 iPad 高分屏上插入消息时清晰不糊
        renderer.scale = 2
        return renderer.uiImage
    }
}

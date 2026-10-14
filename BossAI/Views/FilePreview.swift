// FilePreview.swift —— 文件预览与文件卡片组件集。
// 职责：
//   - QuickLookPreview：桥接系统的 QLPreviewController，免自研解析即可预览
//     PDF/Office/图片/文本等系统支持的格式。
//   - fileTint：按文件类别给出统一的图标配色（视觉语言的一致性）。
//   - FileCardView：对话气泡内的横向文件卡片。
//   - FileGridCard：资料库里的网格文件卡片。
// 用户交互流程：点击卡片触发 onTap（由上层决定弹 QuickLook 预览或分享等）。
// 关键设计决策与防呆/安全冗余：
//   1. 预览直接复用 QuickLook：系统级实现天然覆盖更多格式且随 iOS 升级受益，
//      同时避免自行解析不可信文件带来的安全风险（解析漏洞由系统隔离承担）。
//   2. QLPreviewController 的 dataSource 通过 Coordinator 持有 URL——SwiftUI
//      的 UIViewControllerRepresentable 要求 delegate/dataSource 必须由
//      Coordinator 长期持有，否则会被提前释放导致预览空白。
//   3. 卡片统一使用 .buttonStyle(.plain)：去掉默认按钮样式，避免整块蓝色高亮
//      破坏卡片视觉；点击区域即整卡，触达面积大（易用性防呆）。
//   4. 卡片宽度/布局做了上限约束（如 maxWidth: 360），防止长文件名把对话
//      气泡撑爆。
import SwiftUI
import QuickLook
import UIKit

/// QuickLook 预览（PDF / Word / Excel / PPT / 图片 / 文本 等系统支持的类型）。
/// 把 QLPreviewController 包装成 SwiftUI 可用的视图，单一文件预览。
struct QuickLookPreview: UIViewControllerRepresentable {
    /// 要预览的本地文件地址（须为 QuickLook 支持且可访问的本地 URL）。
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        // dataSource 交给 Coordinator：其生命周期与 SwiftUI 桥接一致，不会被提前释放。
        controller.dataSource = context.coordinator
        return controller
    }

    // 单文件静态预览，无需响应 SwiftUI 状态更新。
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    /// QLPreviewController 的数据源：固定提供 url 指向的这一个文件。
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        // 本视图一次只预览一个文件。
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            // NSURL 本身实现 QLPreviewItem，直接桥接即可。
            url as NSURL
        }
    }
}

/// 文件图标配色。
/// 按类别返回语义化颜色：PDF 红、文档蓝、表格绿、演示橙、图片紫、
/// 文本灰、其他次级色——让用户不读扩展名也能一眼分辨类型。
func fileTint(_ category: FileCategory) -> Color {
    switch category {
    case .pdf: return .red
    case .document: return .blue
    case .spreadsheet: return .green
    case .presentation: return .orange
    case .image: return .purple
    case .text: return .gray
    case .other: return .secondary
    }
}

/// 对话气泡里的文件卡片（横向）。
/// 左侧类别图标 + 文件名/大小/类型，右侧眼睛图标暗示"可点开预览"。
struct FileCardView: View {
    /// 要展示的文件模型。
    let file: StoredFile
    /// 点击回调：由调用方决定预览/分享等行为。
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // 类别图标块：底色用类别的 14% 透明色，形成柔和的色块视觉。
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(fileTint(file.category).opacity(0.14))
                        .frame(width: 38, height: 38)
                    Image(systemName: file.category.symbol)
                        .font(.system(size: 17))
                        .foregroundStyle(fileTint(file.category))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Text("\(file.sizeText) · \(file.kind.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: "eye")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            // 限宽 360：防止超长文件名把对话气泡撑到不可读。
            .frame(maxWidth: 360)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator).opacity(0.6), lineWidth: 0.5)
            )
        }
        // plain 按钮样式：去掉系统默认高亮，保留自定义卡片外观。
        .buttonStyle(.plain)
    }
}

/// 资料库网格卡片。
/// 纵向布局：图标+收藏星标 → 文件名（最多两行）→ 大小与日期。
struct FileGridCard: View {
    /// 要展示的文件模型。
    let file: StoredFile
    /// 点击回调：由调用方决定预览/操作面板等行为。
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // 类别图标块，与 FileCardView 保持同一视觉语言。
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(fileTint(file.category).opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: file.category.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(fileTint(file.category))
                    }
                    Spacer()
                    if file.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(file.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(file.sizeText) · \(file.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

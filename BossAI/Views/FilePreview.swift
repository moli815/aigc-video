import SwiftUI
import QuickLook
import UIKit

/// QuickLook 预览（PDF / Word / Excel / PPT / 图片 / 文本 等系统支持的类型）
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// 文件图标配色
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

/// 对话气泡里的文件卡片（横向）
struct FileCardView: View {
    let file: StoredFile
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
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
            .frame(maxWidth: 360)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(.separator).opacity(0.6), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 资料库网格卡片
struct FileGridCard: View {
    let file: StoredFile
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
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

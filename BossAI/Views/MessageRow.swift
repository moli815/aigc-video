import SwiftUI
import UIKit

/// 消息行：用户右对齐气泡，AI 全宽正文 + 图片 + 文件卡片
struct MessageRow: View {
    let message: Message
    var files: [StoredFile] = []

    @State private var previewFile: StoredFile?

    var body: some View {
        Group {
            if message.role == "user" {
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemBackground),
                                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .textSelection(.enabled)
                    }
                    ForEach(files, id: \.id) { file in
                        FileCardView(file: file) { previewFile = file }
                    }
                }
                .frame(maxWidth: 760, alignment: .trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if let data = message.imageData, let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contextMenu {
                                Button {
                                    UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
                                } label: {
                                    Label("保存到相册", systemImage: "square.and.arrow.down")
                                }
                            }
                            .accessibilityLabel("生成的图片")
                    }
                    ForEach(files, id: \.id) { file in
                        FileCardView(file: file) { previewFile = file }
                    }
                    if !message.text.isEmpty {
                        MarkdownText(message.text)
                            .textSelection(.enabled)
                    } else if message.imageData == nil && files.isEmpty {
                        Text("▍")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
        .sheet(item: $previewFile) { file in
            FilePreviewSheet(file: file)
        }
    }
}

/// 文件预览弹窗（QuickLook + 分享/保存）
struct FilePreviewSheet: View {
    let file: StoredFile
    @Environment(\.dismiss) private var dismiss

    private var url: URL { FileStore.url(for: file) }

    var body: some View {
        NavigationStack {
            Group {
                if FileManager.default.fileExists(atPath: url.path) {
                    QuickLookPreview(url: url)
                } else {
                    ContentUnavailableView("文件已不存在", systemImage: "exclamationmark.triangle")
                }
            }
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if FileManager.default.fileExists(atPath: url.path) {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
    }
}

/// Markdown 渲染（iOS 15+ AttributedString，失败时退化为纯文本）
struct MarkdownText: View {
    private let content: String
    private let attributed: AttributedString?

    init(_ content: String) {
        self.content = content
        self.attributed = try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    var body: some View {
        if let attributed {
            Text(attributed)
        } else {
            Text(content)
        }
    }
}

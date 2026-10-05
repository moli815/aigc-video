import SwiftUI
import UIKit

/// 消息行：用户右对齐气泡，AI 全宽正文 + 图片 + 文件卡片
struct MessageRow: View {
    @Environment(\.appTheme) private var theme
    let message: Message
    /// 非空表示这条消息正在流式输出，展示实时文本而非库里的空文本
    var streamingText: String? = nil
    var files: [StoredFile] = []
    var onPreview: (StoredFile) -> Void = { _ in }

    var body: some View {
        Group {
            if message.role == "user" {
                VStack(alignment: .trailing, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(theme.userBubble,
                                        in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous))
                            .textSelection(.enabled)
                    }
                    ForEach(files, id: \.id) { file in
                        FileCardView(file: file) { onPreview(file) }
                    }
                }
                .frame(maxWidth: theme.messageWidth, alignment: .trailing)
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
                        FileCardView(file: file) { onPreview(file) }
                    }

                    let content = streamingText ?? message.text
                    if !content.isEmpty {
                        // AI 输出区：带清晰边框的卡片
                        MarkdownView(content, collapseDisabled: streamingText != nil)
                            .padding(theme.cardPadding)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                theme.surface.opacity(0.45),
                                in: RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                                    .stroke(theme.border, lineWidth: 0.8)
                            )
                    } else if message.imageData == nil && files.isEmpty && streamingText == nil {
                        Text("▍").foregroundStyle(.secondary)
                    }

                    if streamingText != nil {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在输出…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: theme.messageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
        }
    }
}

/// 文件预览弹窗（QuickLook + 分享/保存）
struct FilePreviewSheet: View {
    @Environment(\.appTheme) private var theme
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

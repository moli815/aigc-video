import SwiftUI
import UIKit

/// 消息行：ChatGPT 风格——用户右对齐浅色气泡，AI 全宽正文 + 图片。
struct MessageRow: View {
    let message: Message

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 720)
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
                if !message.text.isEmpty {
                    MarkdownText(message.text)
                        .textSelection(.enabled)
                } else if message.imageData == nil {
                    // 流式中的空消息：打字光标
                    Text("▍")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
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

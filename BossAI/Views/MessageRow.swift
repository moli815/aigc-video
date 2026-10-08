import SwiftUI
import UIKit
import ImageIO

/// 消息行：用户右对齐气泡，AI 全宽平铺 + 头像 + 图片 + 文件卡片（ChatGPT 式）
struct MessageRow: View {
    @Environment(\.appTheme) private var theme
    let message: Message
    /// 非空表示这条消息正在流式输出，展示实时文本而非库里的空文本
    var streamingText: String? = nil
    var files: [StoredFile] = []
    var onPreview: (StoredFile) -> Void = { _ in }
    /// 是否为最后一条 AI 回复（决定是否显示「重新生成」）
    var isLastAssistant: Bool = false
    var onRegenerate: (() -> Void)? = nil

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
                HStack(alignment: .top, spacing: 10) {
                    AssistantAvatar()
                    VStack(alignment: .leading, spacing: 8) {
                        if let data = message.imageData {
                            MessageImageView(data: data).equatable()
                        }
                        ForEach(files, id: \.id) { file in
                            FileCardView(file: file) { onPreview(file) }
                        }
                        let content = streamingText ?? message.text
                        if !content.isEmpty {
                            AssistantAnswerView(text: content, sourcesJSON: message.sourcesJSON,
                                                streaming: streamingText != nil,
                                                isLastAssistant: isLastAssistant,
                                                onRegenerate: onRegenerate).equatable()
                        } else if message.imageData == nil && files.isEmpty {
                            BlinkingCursor()
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

/// ChatGPT 式 AI 头像（圆形徽标）
private struct AssistantAvatar: View {
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Color.accentColor, in: Circle())
            .accessibilityHidden(true)
    }
}

/// 流式输出尾部闪烁光标（替代 spinner）
private struct BlinkingCursor: View {
    @State private var visible = true
    var body: some View {
        Text("▍")
            .font(.body)
            .foregroundStyle(Color.accentColor)
            .opacity(visible ? 1 : 0.15)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { visible = false }
            }
            .accessibilityHidden(true)
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


/// Value-only subview: streaming a new message does not reparse historical answers.
private struct AssistantAnswerView: View, Equatable {
    let text: String
    let sourcesJSON: String
    let streaming: Bool
    var isLastAssistant: Bool = false
    var onRegenerate: (() -> Void)? = nil
    @State private var copied = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.sourcesJSON == rhs.sourcesJSON && lhs.streaming == rhs.streaming && lhs.isLastAssistant == rhs.isLastAssistant
    }
    var body: some View {
        let projection = CitationPresentation.projection(text: text, json: sourcesJSON)
        VStack(alignment: .leading, spacing: 10) {
            MarkdownView(projection.body, collapseDisabled: streaming).equatable()
            if streaming {
                BlinkingCursor()
            } else {
                // ChatGPT 式：操作按钮在消息底部一排小图标
                HStack(spacing: 18) {
                    Button {
                        UIPasteboard.general.string = text; copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("copy-answer")
                    if isLastAssistant, let onRegenerate {
                        Button(action: onRegenerate) {
                            Label("重新生成", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityIdentifier("regenerate-answer")
                    }
                }
                if !projection.sources.isEmpty {
                    CitationSourcesView(sources: projection.sources, answer: projection.body)
                }
            }
        }
    }
}

struct CitationSourcesView: View {
    let sources: [CitationSource]
    let answer: String
    @State private var showSearchRecords = false
    var body: some View {
        let cited = CitationPresentation.cited(sources, in: answer)
        let known = Set(sources.map(\.id))
        let unknown = CitationPresentation.referencedIDs(in: answer).subtracting(known).sorted()
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("本回答引用来源（\(cited.count) 条）").font(.subheadline.bold())
            if cited.isEmpty {
                Text("本轮检索了 \(sources.count) 条结果，但回答未标明具体引用，请核对原文。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(cited) { source in CitationSourceRow(source: source) }
            if !unknown.isEmpty {
                Text("引用编号 \(unknown.map(String.init).joined(separator: "、")) 未匹配到检索记录，不能作为已核实证据。")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if sources.count > cited.count {
                Button("查看本轮检索记录（\(sources.count) 条）") { showSearchRecords = true }
                    .font(.footnote).accessibilityIdentifier("search-records")
            }
        }
        .sheet(isPresented: $showSearchRecords) {
            NavigationStack {
                List(sources) { source in CitationSourceRow(source: source) }
                    .navigationTitle("本轮检索记录")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { showSearchRecords = false } } }
            }
        }
    }
}

private struct CitationSourceRow: View {
    let source: CitationSource
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link("[\(source.id)] \(source.label)", destination: url)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("citation-\(source.id)")
            } else { Text("[\(source.id)] \(source.label) · 链接不可用") }
            Text(source.domain + " · " + source.dateLabel).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MessageImageView: View, Equatable {
    let data: Data
    @State private var thumbnail: UIImage?
    @State private var loading = true
    @State private var fullscreen = false
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.data == rhs.data }
    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit().frame(maxWidth: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { fullscreen = true }
                    .contextMenu {
                        Button("保存到相册", systemImage: "square.and.arrow.down") {
                            if let original = UIImage(data: data) { UIImageWriteToSavedPhotosAlbum(original, nil, nil, nil) }
                        }
                    }
            } else if loading { ProgressView("正在读取图片…").frame(height: 120) }
            else { Text("图片无法读取，可尝试重新生成。").font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityLabel("生成的图片，点按可放大查看")
        .fullScreenCover(isPresented: $fullscreen) {
            ImageFullscreenView(data: data)
        }
        .task(id: data) {
            let image = await ImageThumbnailWorker.shared.thumbnail(data)
            if !Task.isCancelled { thumbnail = image.map { UIImage(cgImage: $0) }; loading = false }
        }
    }
}

/// 图片全屏预览：双指缩放、双击放大、保存与分享
private struct ImageFullscreenView: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss
    @State private var saved = false
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in scale = min(6, max(1, lastScale * value)) }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                scale = scale > 1 ? 1 : 2; lastScale = scale
                            }
                        }
                }
            }
            .navigationTitle("图片预览").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if let image = UIImage(data: data) {
                            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil); saved = true
                        }
                    } label: {
                        Label(saved ? "已保存" : "保存", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .disabled(saved)
                }
            }
        }
    }
}

actor ImageThumbnailWorker {
    static let shared = ImageThumbnailWorker()
    func thumbnail(_ data: Data) -> CGImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1260,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}

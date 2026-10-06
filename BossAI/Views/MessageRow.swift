import SwiftUI
import UIKit
import ImageIO

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
                    if let data = message.imageData {
                        MessageImageView(data: data).equatable()
                    }

                    ForEach(files, id: \.id) { file in
                        FileCardView(file: file) { onPreview(file) }
                    }

                    let content = streamingText ?? message.text
                    if !content.isEmpty {
                        // AI 输出区：带清晰边框的卡片
                        AssistantAnswerView(text: content, sourcesJSON: message.sourcesJSON, streaming: streamingText != nil).equatable()
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


/// Value-only subview: streaming a new message does not reparse historical answers.
private struct AssistantAnswerView: View, Equatable {
    let text: String
    let sourcesJSON: String
    let streaming: Bool
    var body: some View {
        let projection = CitationPresentation.projection(text: text, json: sourcesJSON)
        VStack(alignment: .leading, spacing: 12) {
            MarkdownView(projection.body, collapseDisabled: streaming).equatable()
            if !streaming && !projection.sources.isEmpty {
                CitationSourcesView(sources: projection.sources, answer: projection.body)
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
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.data == rhs.data }
    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit().frame(maxWidth: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contextMenu {
                        Button("保存到相册", systemImage: "square.and.arrow.down") {
                            if let original = UIImage(data: data) { UIImageWriteToSavedPhotosAlbum(original, nil, nil, nil) }
                        }
                    }
            } else if loading { ProgressView("正在读取图片…").frame(height: 120) }
            else { Text("图片无法读取，可尝试重新生成。").font(.footnote).foregroundStyle(.secondary) }
        }
        .accessibilityLabel("生成的图片")
        .task(id: data) {
            let image = await ImageThumbnailWorker.shared.thumbnail(data)
            if !Task.isCancelled { thumbnail = image.map { UIImage(cgImage: $0) }; loading = false }
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

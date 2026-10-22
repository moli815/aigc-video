//
//  MessageRow.swift
//  BossAI
//
//  聊天消息行及其附属组件（Views 层）：
//  - 职责：单条消息的渲染（用户气泡 / AI 平铺内容 + 图片 + 文件卡片），以及
//    AI 回答的操作按钮（复制 / 重新生成）、引用来源展示、图片预览与缩略图解码。
//  - 交互流程：用户消息右对齐气泡；AI 消息左侧头像 + 全宽 Markdown 正文；
//    流式输出时显示闪烁光标，结束后出现复制/重新生成按钮与引用来源区。
//  - 关键设计决策：
//    1) 流式期间用 streamingText 实时展示文本，库里的 message.text 尚为空——
//       两条数据源在视图内合并，避免流式期间反复写库。
//    2) AssistantAnswerView / MessageImageView 实现 Equatable：
//       新消息流式渲染时历史行仅做值比较，零成本跳过，长会话滚动不卡。
//    3) 引用来源默认折叠到前 5 条（参考豆包），其余按需展开——此前来源列表比正文还长；
//       引用编号若未匹配到检索记录，明确提示"不能作为已核实证据"（防 AI 幻觉引用）。
//    4) 图片缩略图经 ImageThumbnailWorker actor 后台解码，限制最大像素，
//       避免大图在主线程解码造成掉帧与内存峰值。
//    5) 文件预览用 QuickLook，打开前先检查磁盘文件是否存在，失效引用给出明确空态。
//

import SwiftUI
import UIKit
import ImageIO

/// 消息行：用户右对齐气泡，AI 全宽平铺 + 头像 + 图片 + 文件卡片（ChatGPT 式）
struct MessageRow: View {
    @Environment(\.appTheme) private var theme
    /// 消息数据（role/text/imageData/sourcesJSON 等）
    let message: Message
    /// 非空表示这条消息正在流式输出，展示实时文本而非库里的空文本
    var streamingText: String? = nil
    /// 随消息展示的附件文件卡片
    var files: [StoredFile] = []
    /// 点击文件卡片时的预览回调
    var onPreview: (StoredFile) -> Void = { _ in }
    /// 是否为最后一条 AI 回复（决定是否显示「重新生成」）
    var isLastAssistant: Bool = false
    /// 「重新生成」回调；为 nil 时不显示按钮
    var onRegenerate: (() -> Void)? = nil
    /// P0-68 深度思考中（最高档推理模型首字延迟 ~11s）：流式且无正文时显示"深度思考中…"
    var isReasoning: Bool = false

    /// 按角色分流：user 右对齐气泡；AI 左侧头像 + 平铺内容
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
                            .overlay {
                                // 极细的主题色描边：让气泡在深空底上浮起来
                                RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                                    .strokeBorder(theme.accent.opacity(0.30), lineWidth: 1)
                            }
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
                        if let data = message.thumbnailData ?? message.imageData {   // P0-69 缩略图优先（点开预览用原图）
                            MessageImageView(data: data).equatable()
                        }
                        ForEach(files, id: \.id) { file in
                            FileCardView(file: file) { onPreview(file) }
                        }
                        // 两条数据源合并：流式期间用实时文本，否则用库里已存的正文
                        let content = streamingText ?? message.text
                        if !content.isEmpty {
                            AssistantAnswerView(text: content, sourcesJSON: message.sourcesJSON,
                                                streaming: streamingText != nil,
                                                isLastAssistant: isLastAssistant,
                                                onRegenerate: onRegenerate).equatable()
                        } else if message.imageData == nil && files.isEmpty {
                            // 既无文本也无图片/文件：流式刚开始——P0-68 推理中显示"深度思考中…"（消除空等感）
                            if streamingText != nil && isReasoning {
                                ReasoningIndicator()
                            } else {
                                BlinkingCursor()
                            }
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

/// P0-68 深度思考指示（推理模型首字延迟期间显示）：脉动光点 + 文案
struct ReasoningIndicator: View {
    @State private var phase = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(phase ? 1.0 : 0.35)
            Text("深度思考中…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .opacity(phase ? 1.0 : 0.55)
        }
        .padding(.vertical, 6)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { phase = true }
        }
        .accessibilityLabel("深度思考中")
    }
}

/// ChatGPT 式 AI 头像：渐变发光圆徽
private struct AssistantAvatar: View {
    @Environment(\.appTheme) private var theme
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 13, weight: .semibold))
            // 亮色渐变上用深墨图标（白图标压亮青只有 1.8:1，会糊）
            .foregroundStyle(GlassDesign.inkGlyph)
            .frame(width: 28, height: 28)
            .background(Circle().fill(theme.accentGradient))
            .overlay { Circle().strokeBorder(GlassDesign.strokeHighlight, lineWidth: 1) }
            .shadow(color: theme.glow, radius: 7, x: 0, y: 0)
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
/// AI 回答正文子视图（值类型比较）：只有 text/sourcesJSON/streaming/isLastAssistant
/// 四个值都相同才跳过重渲染，流式新消息时历史行零成本复用。
private struct AssistantAnswerView: View, Equatable {
    /// 回答正文（流式期间为增量文本）
    let text: String
    /// 引用来源 JSON（由 CitationPresentation 解析）
    let sourcesJSON: String
    /// 是否处于流式输出中（流式时隐藏操作按钮，只显示光标）
    let streaming: Bool
    /// 是否为最后一条 AI 回复
    var isLastAssistant: Bool = false
    /// 重新生成回调
    var onRegenerate: (() -> Void)? = nil
    /// 复制按钮的"已复制"状态
    @State private var copied = false
    /// 值相等判断：数据没变就整行跳过 diff
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.sourcesJSON == rhs.sourcesJSON && lhs.streaming == rhs.streaming && lhs.isLastAssistant == rhs.isLastAssistant
    }
    var body: some View {
        // 投影：把正文拆成"引用标记剥离后的正文 + 来源列表"，正文交给 MarkdownView
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

/// 引用来源展示区：列出被正文实际引用的来源，未匹配的编号给出警示，另可查看全部检索记录
struct CitationSourcesView: View {
    /// 本轮检索得到的全部来源
    let sources: [CitationSource]
    /// 剥离引用标记后的回答正文（用于判断哪些来源被实际引用）
    let answer: String
    /// 是否弹出"全部检索记录"sheet
    @State private var showSearchRecords = false
    // P0-12：来源默认只展示前 5 条（参考豆包），其余折叠——此前源列表比正文还长
    @State private var showAllSources = false
    var body: some View {
        // cited：正文里真实引用（[N]）的来源；unknown：正文出现 [N] 但检索记录里没有的编号
        let cited = CitationPresentation.cited(sources, in: answer)
        let known = Set(sources.map(\.id))
        let unknown = CitationPresentation.referencedIDs(in: answer).subtracting(known).sorted()
        let visible = showAllSources ? cited : Array(cited.prefix(5))
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("引用来源（\(cited.count) 条）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            // 检索了但没有一条被引用：如实告知，提示用户自行核对（防幻觉引用的诚实设计）
            if cited.isEmpty {
                Text("本轮检索了 \(sources.count) 条结果，但回答未标明具体引用，请核对原文。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(visible) { source in CitationSourceRow(source: source) }
            if cited.count > 5 {
                Button(showAllSources ? "收起" : "展开其余 \(cited.count - 5) 条") {
                    withAnimation(.easeInOut(duration: 0.18)) { showAllSources.toggle() }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("toggle-sources")
            }
            // 正文引用了不存在的编号：橙色警示，明确声明"不能作为已核实证据"——AI 幻觉防呆
            if !unknown.isEmpty {
                Text("引用编号 \(unknown.map(String.init).joined(separator: "、")) 未匹配到检索记录，不能作为已核实证据。")
                    .font(.caption2).foregroundStyle(.orange)
            }
            // 检索条数多于被引用条数：提供入口查看全部原始检索记录，保证可溯源
            if sources.count > cited.count {
                Button("查看本轮检索记录（\(sources.count) 条）") { showSearchRecords = true }
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("search-records")
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

/// 单条来源行：可点的标题链接 + 域名与日期；非法/不可用链接降级为纯文本并标注
private struct CitationSourceRow: View {
    /// 一条检索来源（id/label/url/domain/dateLabel）
    let source: CitationSource
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 只放行 http/https 链接：其他 scheme（如 javascript:）直接降级为纯文本，防止注入
            if let url = URL(string: source.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                Link("[\(source.id)] \(source.label)", destination: url)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("citation-\(source.id)")
            } else { Text("[\(source.id)] \(source.label) · 链接不可用").font(.caption) }
            Text(source.domain + " · " + source.dateLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }
}

/// 消息内图片：后台解码缩略图 + 点击全屏 + 长按保存相册；值相等只看二进制数据
private struct MessageImageView: View, Equatable {
    /// 图片原始数据
    let data: Data
    /// 后台解码出的缩略图
    @State private var thumbnail: UIImage?
    /// 缩略图解码中
    @State private var loading = true
    /// 是否打开全屏预览
    @State private var fullscreen = false
    /// 值相等判断：数据没变就跳过重渲染（解码不重复触发）
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
            // 缩略图在 actor 后台解码：大图不在主线程解码，避免滚动掉帧
            let image = await ImageThumbnailWorker.shared.thumbnail(data)
            // 任务可能已被取消（视图销毁/数据变化），取消后不再写状态
            if !Task.isCancelled { thumbnail = image.map { UIImage(cgImage: $0) }; loading = false }
        }
    }
}

/// 图片全屏预览：双指缩放、双击放大、保存与分享
private struct ImageFullscreenView: View {
    /// 图片原始数据
    let data: Data
    @Environment(\.dismiss) private var dismiss
    /// 保存成功标记（保存一次后按钮禁用，防止重复写入相册）
    @State private var saved = false
    /// 当前缩放倍数（1–6 倍钳制）
    @State private var scale: CGFloat = 1
    /// 手势结束时的缩放基数，下一次捏合从它累乘
    @State private var lastScale: CGFloat = 1
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            // 捏合缩放：以 lastScale 为基数累乘，钳制在 1–6 倍，防止缩过头
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

/// 图片缩略图后台解码 actor：ImageIO 按最大边 1260px 出图，立即解码不延迟
actor ImageThumbnailWorker {
    static let shared = ImageThumbnailWorker()
    /// 生成缩略图；输入无效或任务已取消时返回 nil
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

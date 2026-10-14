//
//  LibraryView.swift
//  BossAI
//
//  资料库界面（Views 层）：
//  - 职责：集中展示本机保存的所有文件（用户上传的 + AI 生成的），是"文件资产"的唯一入口。
//  - 交互流程：进入页面 → 顶部筛选条（全部/我上传的/AI 生成的/收藏/分类 Chip）→ 网格卡片浏览；
//    长按卡片弹出上下文菜单（收藏 / 分享 / 回到来源对话 / 删除）；点击卡片进入预览弹窗。
//  - 关键设计决策：
//    1) 数据全部来自 SwiftData @Query，按创建时间倒序，本地优先、无需网络。
//    2) 搜索同时匹配文件名与已抽取的文本内容（textContent），保证"只记得内容"也能找到文件。
//    3) 删除必须经过确认弹窗，并明示"永久删除、无法恢复"——防呆设计，避免误删唯一副本。
//    4) 分享按钮仅在磁盘文件真实存在时才出现，避免把失效引用分享出去。
//    5) "回到来源对话"按来源会话 ID 跳转，保留文件的产生语境。
//

import SwiftUI
import SwiftData

/// 资料库：本地保存所有上传与 AI 生成的文件，支持筛选、搜索、预览、分享、收藏、删除
struct LibraryView: View {
    /// 当前主题（颜色 / 圆角 / 辉光等设计令牌），由全局环境注入
    @Environment(\.appTheme) private var theme
    /// 点击"回到来源对话"时回调给上层，由上层负责切换到对应会话（视图不直接持有会话导航）
    var onOpenConversation: (UUID) -> Void = { _ in }

    /// SwiftData 上下文，用于删除文件与收藏持久化
    @Environment(\.modelContext) private var modelContext
    /// 全量文件查询，按创建时间倒序（最新的排前面，符合"最近用过的最先看到"的直觉）
    @Query(sort: \StoredFile.createdAt, order: .reverse) private var allFiles: [StoredFile]

    /// 类型筛选（上传/生成），nil 表示不按类型过滤
    @State private var kindFilter: FileKind?
    /// 分类筛选（文档/表格/图片等），nil 表示不过滤
    @State private var categoryFilter: FileCategory?
    /// 仅显示收藏文件
    @State private var favoritesOnly = false
    /// 搜索关键词：同时匹配文件名与抽取文本
    @State private var searchText = ""
    /// 当前正在预览的文件（非空时弹出预览 sheet）
    @State private var previewFile: StoredFile?
    /// 待确认删除的文件：先挂起，等确认弹窗点击"删除"才真正删除——防止误触
    @State private var pendingDelete: StoredFile?
    /// 文件操作失败信息，展示在页面底部
    @State private var fileError: String?

    // 自适应网格：宽度至少 190pt，iPad 横竖屏都能自动调整列数，无需手写多套布局
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    /// 应用全部筛选条件后的文件列表（类型 + 分类 + 收藏 + 关键词）
    private var files: [StoredFile] {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        return allFiles.filter { file in
            if let kindFilter, file.kind != kindFilter { return false }
            if let categoryFilter, file.category != categoryFilter { return false }
            if favoritesOnly, !file.isFavorite { return false }
            if !keyword.isEmpty {
                let hitName = file.name.localizedCaseInsensitiveContains(keyword)
                let hitText = file.textContent.localizedCaseInsensitiveContains(keyword)
                if !hitName && !hitText { return false }
            }
            return true
        }
    }

    /// 页面主体：头部统计 → 筛选条 → 文件网格 / 空态，并挂载预览 sheet 与删除确认弹窗
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                header
                filterBar

                if files.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(files, id: \.id) { file in
                            FileGridCard(file: file) { previewFile = file }
                                // 长按菜单：高频操作不进二级页面，就地完成
                                .contextMenu {
                                    Button {
                                        toggleFavorite(file)
                                    } label: {
                                        Label(file.isFavorite ? "取消收藏" : "收藏",
                                              systemImage: file.isFavorite ? "star.slash" : "star")
                                    }
                                    // 分享前检查磁盘文件是否存在：SwiftData 记录可能指向已被清理的文件
                                    if FileManager.default.fileExists(atPath: FileStore.url(for: file).path) {
                                        ShareLink(item: FileStore.url(for: file)) {
                                            Label("分享", systemImage: "square.and.arrow.up")
                                        }
                                    }
                                    if let uuid = UUID(uuidString: file.sourceConversationId) {
                                        Button {
                                            onOpenConversation(uuid)
                                        } label: {
                                            Label("回到来源对话", systemImage: "arrow.uturn.backward")
                                        }
                                    }
                                    Button(role: .destructive) {
                                        pendingDelete = file
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .padding(20)
        }
        // 透明底：让深空渐变与玻璃卡片形成层级
        .background(Color.clear)
        .overlay(alignment: .bottom) { if let fileError { Text(fileError).font(.footnote).foregroundStyle(.red).padding() } }
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索文件名或内容")
        .sheet(item: $previewFile) { file in
            FilePreviewSheet(file: file)
        }
        // 删除确认弹窗：用 Binding 把 pendingDelete 与弹窗状态绑定，取消/关闭都会清空挂起对象——避免下次打开残留
        .alert("删除文件", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let file = pendingDelete {
                    do { try FileStore.delete(file, context: modelContext) }
                    catch { fileError = error.localizedDescription }
                }
                pendingDelete = nil
            }
        } message: {
            Text("「\(pendingDelete?.name ?? "")」将从本机永久删除，无法恢复。")
        }
    }

    /// 顶部标题区：图标 + 文件总数与总占用空间，给用户"资产全貌"的心理确认
    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(ThemeStore.current.accentSoft)
                    .frame(width: 46, height: 46)
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("资料库")
                    .font(.headline)
                Text("\(allFiles.count) 个文件 · 共 \(totalSizeText)，全部保存在本机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// 横向筛选条：类型 / 收藏 Chip + 动态生成的分类 Chip（只显示库里实际存在的分类，避免无效选项）
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "全部", active: kindFilter == nil && !favoritesOnly) {
                    kindFilter = nil
                    favoritesOnly = false
                }
                FilterChip(title: "我上传的", active: kindFilter == .uploaded) {
                    kindFilter = .uploaded
                    favoritesOnly = false
                }
                FilterChip(title: "AI 生成的", active: kindFilter == .generated) {
                    kindFilter = .generated
                    favoritesOnly = false
                }
                FilterChip(title: "收藏", symbol: "star.fill", active: favoritesOnly) {
                    favoritesOnly = true
                    kindFilter = nil
                }

                if categoryFilter != nil || kindFilter != nil || favoritesOnly {
                    Divider().frame(height: 20)
                }

                // 只渲染库中存在文件的分类：全空分类的 Chip 没有信息量，只会增加噪音
                ForEach(FileCategory.allCases) { category in
                    if allFiles.contains(where: { $0.category == category }) {
                        FilterChip(title: category.displayName,
                                   symbol: category.symbol,
                                   active: categoryFilter == category) {
                            categoryFilter = categoryFilter == category ? nil : category
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// 空态视图：区分"库整体为空"（给引导文案）与"筛选无结果"（提示放宽条件）两种情形
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text(allFiles.isEmpty ? "资料库还是空的" : "没有符合筛选条件的文件")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if allFiles.isEmpty {
                Text("在对话里点「+」上传文件，或让 AI 直接生成 Word / PPT / Excel")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    /// 库内全部文件的总大小（人类可读格式），用于头部统计文案
    private var totalSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(allFiles.reduce(0) { $0 + $1.byteCount }))
    }

    /// 收藏 / 取消收藏并立即落库：收藏是用户主动标记，必须持久化，不能只留在内存
    private func toggleFavorite(_ file: StoredFile) {
        file.isFavorite.toggle()
        try? modelContext.save()
    }
}

/// 筛选胶囊按钮：激活态用主题色浅底 + 描边区分，是本页与筛选相关的通用小控件
struct FilterChip: View {
    @Environment(\.appTheme) private var theme
    /// 按钮文字
    let title: String
    /// 可选 SF Symbol 图标
    var symbol: String? = nil
    /// 是否处于激活（选中）状态
    let active: Bool
    /// 点击回调
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11))
                }
                Text(title).font(.footnote)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(active ? ThemeStore.current.accentSoft : theme.surface,
                        in: Capsule())
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .overlay(
                Capsule().stroke(active ? ThemeStore.current.accent.opacity(0.5) : Color.clear, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }
}

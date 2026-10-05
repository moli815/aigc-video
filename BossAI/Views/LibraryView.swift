import SwiftUI
import SwiftData

/// 资料库：本地保存所有上传与 AI 生成的文件，支持筛选、搜索、预览、分享、收藏、删除
struct LibraryView: View {
    @Environment(\.appTheme) private var theme
    var onOpenConversation: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredFile.createdAt, order: .reverse) private var allFiles: [StoredFile]

    @State private var kindFilter: FileKind?
    @State private var categoryFilter: FileCategory?
    @State private var favoritesOnly = false
    @State private var searchText = ""
    @State private var previewFile: StoredFile?
    @State private var pendingDelete: StoredFile?
    @State private var fileError: String?

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

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
                                .contextMenu {
                                    Button {
                                        toggleFavorite(file)
                                    } label: {
                                        Label(file.isFavorite ? "取消收藏" : "收藏",
                                              systemImage: file.isFavorite ? "star.slash" : "star")
                                    }
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
        .background(theme.canvas)
        .overlay(alignment: .bottom) { if let fileError { Text(fileError).font(.footnote).foregroundStyle(.red).padding() } }
        .navigationTitle("资料库")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索文件名或内容")
        .sheet(item: $previewFile) { file in
            FilePreviewSheet(file: file)
        }
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

    private var totalSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(allFiles.reduce(0) { $0 + $1.byteCount }))
    }

    private func toggleFavorite(_ file: StoredFile) {
        file.isFavorite.toggle()
        try? modelContext.save()
    }
}

struct FilterChip: View {
    @Environment(\.appTheme) private var theme
    let title: String
    var symbol: String? = nil
    let active: Bool
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

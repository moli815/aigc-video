import SwiftUI
import SwiftData

/// 身份设置：显式身份 + 记忆管理（查看/删除/清空）。
/// Modal Sheet，带取消按钮与下滑关闭手势。
struct IdentitySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MemoryItem.createdAt, order: .reverse) private var memories: [MemoryItem]

    @State private var identity = UserIdentity.load()
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("姓名 / 称呼", text: $identity.name)
                    TextField("公司", text: $identity.company)
                    TextField("行业", text: $identity.industry)
                    TextField("身份（如：创始人 / 总经理）", text: $identity.role)
                    TextField("当前最想解决的经营问题", text: $identity.goal, axis: .vertical)
                        .lineLimit(2...4)
                } header: {
                    Text("对话者身份")
                } footer: {
                    Text("设置后，所有对话的回答都会结合你的身份背景，更贴合实际经营场景。")
                }

                Section {
                    if memories.isEmpty {
                        Text("暂无记忆。随着对话进行，Boss AI 会自动记住你的公司、项目和偏好。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(memories, id: \.id) { item in
                            Text(item.content)
                                .font(.footnote)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        modelContext.delete(item)
                                        try? modelContext.save()
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                        Button("清空全部记忆", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                } header: {
                    Text("长期记忆（\(memories.count) 条）")
                } footer: {
                    Text("记忆只保存在本机，可随时删除或清空。")
                }
            }
            .navigationTitle("身份设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        identity.save()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .confirmationDialog("确定清空全部长期记忆？", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("清空", role: .destructive) {
                    for m in memories { modelContext.delete(m) }
                    try? modelContext.save()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

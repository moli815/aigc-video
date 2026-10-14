import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// 文件职责：自定义专家管理页（Ultra 权益）——列出/新建/删除专属专家，
// 资料以纯文本粘贴上传，知识库存服务端并按账号隔离自动分块。
//
// 在整个 App 中的角色：
//   入口在身份设置/会员页；创建后专家出现在对话内（服务端按关键词检索注入），
//   ChatViewModel 的 capabilityPrompt（P0-21）会向模型声明该能力。
//
// 关键设计决策：
//   1. 知识放服务端而非本地：换设备、多端登录都能用，且检索注入由服务端统一做；
//   2. 表单防呆：知识内容 ≥50 字才允许提交，按钮禁用态 + 字数实时提示；
//   3. monogram 徽章（P0-23）：头像与侧边栏专家列表同一视觉语言
//      （首字 + 固定 frame + ExpertRow.tint(for:) 稳定配色），
//      避免 SF Symbol 视觉宽度差异导致的对齐问题。
// ─────────────────────────────────────────────────────────────────────────────

/// P0-19 自定义专家（Ultra 权益）：上传/粘贴资料生成专属专家。
/// 知识库存服务端（按账号隔离，自动分块），对话时服务端按关键词检索注入，所有会话生效。
struct CustomExpertView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var experts: [[String: Any]] = []
    @State private var loading = true
    @State private var showCreate = false
    @State private var newName = ""
    @State private var newSubtitle = ""
    @State private var newKnowledge = ""
    @State private var submitting = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !HostedAccount.cachedCustomExpertEnabled {
                        upsellCard
                    } else {
                        createCard
                        ForEach(Array(experts.enumerated()), id: \.offset) { _, expert in
                            expertRow(expert)
                        }
                        if experts.isEmpty, !loading {
                            Text("还没有自定义专家。粘贴你的公司资料、产品手册、报价体系等，专家就能在对话中准确回答。")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("自定义专家")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await load() }
    }

    /// 未开通权益时的升级引导卡（去了解 Ultra）
    private var upsellCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.square.badge.plus").font(.system(size: 40)).foregroundStyle(theme.accent)
            Text("自定义专家是 Ultra 旗舰版权益").font(.headline)
            Text("上传公司资料、产品手册、报价体系，生成只懂你业务的专属专家，所有对话自动参考。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { dismiss(); } label: {
                Text("去了解 Ultra")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(theme.accentDeepGradient, in: Capsule())
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 40)
    }

    /// 新建专家表单卡：名称/介绍/知识内容输入 + 字数统计 + 提交按钮
    /// （知识 <50 字或名称为空时按钮禁用；提交中显示进度并防重复点击）
    private var createCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新建专家").font(.subheadline.weight(.bold))
            TextField("专家名称（如：中防公司顾问）", text: $newName)
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .font(.subheadline)
            TextField("一句话介绍（选填）", text: $newSubtitle)
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .font(.subheadline)
            TextField("知识内容：粘贴公司资料、产品介绍、报价、售后政策等（至少 50 字）",
                      text: $newKnowledge, axis: .vertical)
                .lineLimit(6...12)
                .padding(10)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                .font(.footnote)
            HStack {
                Text("\(newKnowledge.count) 字")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await create() }
                } label: {
                    HStack {
                        if submitting { ProgressView().controlSize(.mini).tint(.white) }
                        Text(submitting ? "创建中…" : "生成专家")
                            .font(.footnote.weight(.bold))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(theme.accentDeepGradient, in: Capsule())
                    .foregroundStyle(.white)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(submitting || newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newKnowledge.trimmingCharacters(in: .whitespaces).count < 50)
            }
            if let errorText {
                Text(errorText).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    /// 单个专家行：monogram 徽章 + 名称 + 知识库分块数 + 删除按钮
    private func expertRow(_ expert: [String: Any]) -> some View {
        let name = expert["name"] as? String ?? ""
        let subtitle = expert["subtitle"] as? String ?? ""
        let chunks = (expert["chunkCount"] as? NSNumber)?.intValue ?? 0
        let id = expert["id"] as? String ?? ""
        return HStack(spacing: 11) {
            // P0-23 与侧边栏专家列表统一 monogram 徽章（SF Symbol 对齐问题根治方案）
            Text(String(name.prefix(1)))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(ExpertRow.tint(for: id.isEmpty ? name : id),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.footnote.weight(.bold))
                Text(subtitle.isEmpty ? "知识库 \(chunks) 段" : subtitle + " · \(chunks) 段")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await remove(id) }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 30, height: 30)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除专家 \(name)")
        }
        .padding(11)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    /// 从服务端拉取当前账号的自定义专家列表
    private func load() async {
        loading = true
        experts = await HostedAccount.shared.fetchCustomExperts()
        loading = false
    }

    /// 提交创建：成功后清空表单并刷新列表；失败转成友好错误文案展示
    private func create() async {
        submitting = true
        errorText = nil
        do {
            try await HostedAccount.shared.createCustomExpert(
                name: newName.trimmingCharacters(in: .whitespaces),
                subtitle: newSubtitle.trimmingCharacters(in: .whitespaces),
                knowledge: newKnowledge)
            newName = ""; newSubtitle = ""; newKnowledge = ""
            await load()
        } catch {
            errorText = FriendlyError.message(for: error, scene: .generic)
        }
        submitting = false
    }

    /// 删除指定专家（失败静默，随后统一刷新列表反映服务端真实状态）
    private func remove(_ id: String) async {
        _ = try? await HostedAccount.shared.deleteCustomExpert(id: id)
        await load()
    }
}

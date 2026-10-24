// InputBar.swift —— 对话输入条：附件、语音输入、文本框与发送/停止。
// 职责：提供多来源附件入口（拍照/相册/文件，经 confirmationDialog 汇聚）、
//   麦克风语音听写、可增高的多行文本输入，以及发送/停止输出按钮；
//   发送前以附件胶囊形式展示待发送附件。
// 用户交互流程：点"+"选择附件来源 → 附件显示为可删除胶囊 → 输入文本或
//   语音听写（录音时麦克风变红色停止按钮，实时把识别文本拼到草稿后）→
//   发送可用时点箭头发送；流式输出期间箭头变为红色停止按钮。
// 关键设计决策与防呆/安全冗余：
//   1. canSend 联合校验：有文本或附件、且未在流式输出/读文件/录音中才允许
//      发送，杜绝竞态（如一边流式一边发新消息）。
//   2. 语音防呆：isStarting/isStreaming/isImporting 期间禁用麦克风；开始录音
//      前快照当前文本到 speechDraft，识别文本始终追加在草稿之后，避免覆盖
//      用户已输入内容；onDisappear 强制停止录音，防止页面销毁后麦克风仍占用。
//   3. 相机防呆：先探测 isSourceTypeAvailable(.camera)，iPad 无相机时回退到
//      相册；CameraPicker 内部同样有回退逻辑（双保险）。
//   4. 相册限选 10 张且仅图片；单张解析失败静默跳过，不中断整批导入。
//   5. 语音错误用 alert 提示并复位 errorMessage（.constant 绑定 + 按钮回调清除）。
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 输入条：附件（拍照 / 相册 / 文件）+ 麦克风语音输入 + 文本框 + 发送。
/// 自上而下：导入进度条 → 待发送附件胶囊 → 主输入行（+ / 麦克风 / 文本框 / 发送）。
struct InputBar: View {
    @Environment(\.appTheme) private var theme
    /// 对话视图模型：输入文本、附件队列、流式状态都由它持有。
    @ObservedObject var viewModel: ChatViewModel
    /// 语音听写服务（独立状态对象，生命周期跟随本视图）。
    @StateObject private var speech = SpeechService()

    @State private var showSourceDialog = false
    /// 开始录音时对已输入文本的快照；识别文本会拼接到它后面。
    @State private var speechDraft = ""
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    /// 相册多选的临时载体，选择完成后立即清空（防重复触发 onChange）。
    @State private var photoItems: [PhotosPickerItem] = []
    /// 键盘焦点变化回调（10-24）：交给 ChatView 在键盘弹出/收起后校正滚动位置。
    /// 焦点状态本身留在 InputBar 内（避免把 @FocusState 提升到父视图引发整页重绘），只把事件抛出去。
    var onFocusChanged: ((Bool) -> Void)? = nil

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isImporting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取文件…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }

            if !viewModel.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.pendingAttachments, id: \.id) { file in
                            AttachmentChip(file: file) {
                                viewModel.removeAttachment(file)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 6) {
                Button {
                    showSourceDialog = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 42, height: 42)
                        .liquidGlassCompat(Circle(), elevated: false)
                }
                .accessibilityLabel("添加附件")

            // 语音按钮：开始/停止录音。开始前快照草稿（补一个换行分隔），
            // 停止时把草稿 + 最终识别文本一次性写回输入框。
                Button {
                    if speech.isRecording {
                        speech.stop()
                        viewModel.inputText = speechDraft + speech.recognizedText
                    } else {
                        speechDraft = viewModel.inputText
                        if !speechDraft.isEmpty && !speechDraft.hasSuffix("\n") { speechDraft += "\n" }
                        Task { await speech.start() }
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                        .frame(width: 42, height: 42)
                        .liquidGlassCompat(Circle(), elevated: false)
                }
                // 录音启动中/流式输出/读文件期间禁用麦克风，防止状态互相踩踏。
                .disabled(speech.isStarting || viewModel.isStreaming || viewModel.isImporting)
                .accessibilityLabel(speech.isRecording ? "停止录音" : "语音输入")

                TextField("描述任务、目标或需要核实的信息…", text: inputBinding, axis: .vertical)
                    .accessibilityIdentifier("task-input")
                    .lineLimit(1...6)
                    .focused($focused)
                    .onChange(of: focused) { _, isFocused in onFocusChanged?(isFocused) }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    // 输入框做成独立玻璃胶囊，交互指向更明确
                    .liquidGlassCompat(RoundedRectangle(cornerRadius: 22, style: .continuous), elevated: false)

                // 流式输出期间发送按钮变为"停止输出"，避免误发新消息。
                if viewModel.isStreaming {
                    Button {
                        viewModel.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.red)
                            .frame(width: 42, height: 42)
                    }
                    .accessibilityLabel("停止输出")
                } else {
                    Button {
                        viewModel.send()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(canSend ? Color.white : Color.white.opacity(0.35))
                            .frame(width: 42, height: 42)
                            .background {
                                // 实底承载白箭头：用加深后的 accentDeep，白字对比度 ≥ 4.6
                                if canSend { Circle().fill(theme.accentDeepGradient) }
                                else { Circle().fill(Color.white.opacity(0.08)) }
                            }
                            .overlay { Circle().strokeBorder(GlassDesign.strokeHighlight, lineWidth: 1) }
                            .shadow(color: canSend ? theme.glow : .clear, radius: 9)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                    .accessibilityIdentifier("send-button")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        // 整条输入区做成玻璃面板，顶部一条发丝线分隔对话区
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(theme.border).frame(height: 0.5) }
        // 语音识别实时回写：录音中每次识别更新都把"草稿 + 识别文本"写入输入框。
        .onChange(of: speech.recognizedText) { _, newValue in
            if speech.isRecording { viewModel.inputText = speechDraft + newValue }
        }
        // 离开页面必须停止录音，释放麦克风且避免后台继续识别。
        .onDisappear { speech.stop() }
        // 附件来源选择：拍照前先探测相机可用性，无相机（部分 iPad）回退到相册。
        .confirmationDialog("添加附件", isPresented: $showSourceDialog, titleVisibility: .visible) {
            Button("拍照") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) { showCamera = true }
                else { showPhotos = true }
            }
            Button("从相册选择") { showPhotos = true }
            Button("选择文件") { showFiles = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("支持 PDF、Word、Excel、PPT、文本与图片，可多选")
        }
        // 相册多选：限 10 张、仅图片；单张解析失败跳过，不中断整批。
        .photosPicker(isPresented: $showPhotos, selection: $photoItems,
                      maxSelectionCount: 10, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }
                photoItems = []
                viewModel.attach(images: images)
            }
        }
        .fileImporter(isPresented: $showFiles,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                viewModel.attach(urls: urls)
            } else if case .failure(let error) = result {
                viewModel.errorMessage = "文件读取失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                viewModel.attach(images: [image])
            }
            .ignoresSafeArea()
        }
        .alert("语音输入不可用", isPresented: .constant(speech.errorMessage != nil)) {
            Button("好", role: .cancel) { speech.errorMessage = nil }
        } message: {
            Text(speech.errorMessage ?? "")
        }
    }

    /// 发送许可的联合校验：有内容（文本或附件）且所有异步状态（流式/导入/录音）
    /// 都不在进行中，防止并发操作互相干扰。
    private var canSend: Bool {
        (!viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
         || !viewModel.pendingAttachments.isEmpty)
            && !viewModel.isStreaming && !viewModel.isImporting && !speech.isRecording && !speech.isStarting
    }

    /// 文本框绑定：桥接 viewModel.inputText（viewModel 是 class，需显式 Binding）。
    private var inputBinding: Binding<String> {
        Binding(get: { viewModel.inputText }, set: { viewModel.inputText = $0 })
    }
}

/// 附件小卡片（带删除）。
/// 胶囊造型：类别图标 + 文件名/大小 + 删除按钮；限宽 190 防止长文件名撑爆横滑条。
struct AttachmentChip: View {
    @Environment(\.appTheme) private var theme
    /// 要展示的待发送附件。
    let file: StoredFile
    /// 删除回调。
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: file.category.symbol)
                .font(.footnote)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.caption2)
                    .lineLimit(1)
                Text(file.sizeText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface, in: Capsule())
        .frame(maxWidth: 190)
    }
}

/// 相机（iPad 无相机时自动回退到相册）。
/// 包装 UIImagePickerController；回调返回原图并关闭。
struct CameraPicker: UIViewControllerRepresentable {
    /// 拍摄完成回调（传入原图 UIImage）。
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // 双保险回退：构造时再次探测相机，不可用则直接用照片库。
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        // delegate 必须由 Coordinator 持有，防止提前释放导致回调丢失。
        picker.delegate = context.coordinator
        return picker
    }

    // 静态选择器，无需响应 SwiftUI 状态更新。
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// UIImagePickerController 回调代理：完成时回调原图并关闭，取消时仅关闭。
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

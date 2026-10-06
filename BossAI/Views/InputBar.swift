import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 输入条：附件（拍照 / 相册 / 文件）+ 麦克风语音输入 + 文本框 + 发送
struct InputBar: View {
    @Environment(\.appTheme) private var theme
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var speech = SpeechService()

    @State private var showSourceDialog = false
    @State private var speechDraft = ""
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
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
                        .background(theme.surface, in: Circle())
                }
                .accessibilityLabel("添加附件")

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
                }
                .disabled(speech.isStarting || viewModel.isStreaming || viewModel.isImporting)
                .accessibilityLabel(speech.isRecording ? "停止录音" : "语音输入")

                TextField("描述任务、目标或需要核实的信息…", text: inputBinding, axis: .vertical)
                    .accessibilityIdentifier("task-input")
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(.separator), lineWidth: 1)
                    )

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
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? Color.accentColor : Color(.systemGray4))
                            .frame(width: 42, height: 42)
                    }
                    .disabled(!canSend)
                    .accessibilityLabel("发送")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(.bar)
        .onChange(of: speech.recognizedText) { _, newValue in
            if speech.isRecording { viewModel.inputText = speechDraft + newValue }
        }
        .onDisappear { speech.stop() }
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

    private var canSend: Bool {
        (!viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
         || !viewModel.pendingAttachments.isEmpty)
            && !viewModel.isStreaming && !viewModel.isImporting && !speech.isRecording && !speech.isStarting
    }

    private var inputBinding: Binding<String> {
        Binding(get: { viewModel.inputText }, set: { viewModel.inputText = $0 })
    }
}

/// 附件小卡片（带删除）
struct AttachmentChip: View {
    @Environment(\.appTheme) private var theme
    let file: StoredFile
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

/// 相机（iPad 无相机时自动回退到相册）
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

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

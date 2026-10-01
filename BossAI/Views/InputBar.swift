import SwiftUI

/// 输入条：麦克风（语音输入）+ 文本框 + 发送。ChatGPT 风格胶囊造型。
struct InputBar: View {
    @ObservedObject var viewModel: ChatViewModel
    @StateObject private var speech = SpeechService()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // 语音输入按钮
            Button {
                if speech.isRecording {
                    speech.stop()
                    viewModel.inputText = speech.recognizedText
                } else {
                    Task { await speech.start() }
                }
            } label: {
                Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(speech.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(speech.isRecording ? "停止录音" : "语音输入")

            // 文本框（语音识别的中间结果实时回填）
            TextField("发消息…", text: inputBinding, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )

            // 发送
            Button {
                viewModel.send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        canSend ? Color.accentColor : Color(.systemGray4)
                    )
                    .frame(width: 44, height: 44)
            }
            .disabled(!canSend)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: speech.recognizedText) { _, newValue in
            if speech.isRecording {
                viewModel.inputText = newValue
            }
        }
        .alert("语音输入不可用", isPresented: .constant(speech.errorMessage != nil)) {
            Button("好", role: .cancel) { speech.errorMessage = nil }
        } message: {
            Text(speech.errorMessage ?? "")
        }
    }

    private var canSend: Bool {
        !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isStreaming
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { viewModel.inputText },
            set: { viewModel.inputText = $0 }
        )
    }
}

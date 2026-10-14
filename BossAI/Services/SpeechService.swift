import Foundation
import Speech
import AVFoundation

// ============================================================================
// 文件职责：语音输入（中文语音识别）。
// 在 App 中的角色：输入栏麦克风按钮的引擎——用原生 Speech 框架（zh-CN）做
//   实时识别，部分结果即时回填输入框，停止后保留最终文本。
// 关键设计决策与防呆：
//   1. generation 令牌：每次 start() 换新 UUID，识别回调只接受最新一代——
//      防止快速启停时上一轮回调污染新一轮文本（竞态防呆）；
//   2. 权限在首次点击麦克风时按需请求，不在启动时弹窗；
//   3. stopTaskOnly 统一清理引擎/tap/请求/任务/音频会话，任何路径退出都不泄漏资源。
// ============================================================================

/// 语音输入：原生 Speech 框架（zh-CN），识别文本实时回填输入框。
@MainActor
final class SpeechService: ObservableObject {
    /// 是否正在录音（驱动麦克风按钮动画/状态）
    @Published var isRecording = false
    /// 实时识别文本（部分结果随讲随更新）
    @Published var recognizedText = ""
    /// 正在启动中（权限请求/引擎预热期间，防止重复点击）
    @Published private(set) var isStarting = false
    private var tapInstalled = false
    /// 当前代际令牌：start 换新、stop 作废；回调据此判断自己是否已"过期"
    private var generation = UUID()
    /// 权限/启动/识别失败原因（UI 弹提示）
    @Published var errorMessage: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// 在首次点击麦克风时按上下文请求权限（不在启动时请求）
    func requestPermissions() async -> Bool {
        let speechOK = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechOK else { errorMessage = "请在系统设置中允许语音识别"; return false }
        let micOK = await AVAudioApplication.requestRecordPermission()
        if !micOK { errorMessage = "请在系统设置中允许麦克风访问" }
        return micOK
    }

    /// 开始录音与识别：请求权限 → 配置音频会话 → 建 buffer 识别请求 → 安装输入 tap → 启动引擎。
    /// 防抖：isStarting/isRecording 双重守卫；启动期间用户再次点击直接忽略。
    /// 失败行为：设置 errorMessage 并回滚已启动的部分（stopTaskOnly）。
    func start() async {
        guard !isStarting, !isRecording else { return }
        isStarting = true
        let token = UUID(); generation = token
        defer { isStarting = false }
        guard await requestPermissions(), generation == token, !Task.isCancelled else { return }
        guard recognizer?.isAvailable == true else { errorMessage = "语音识别服务当前不可用，请稍后重试"; return }
        stopTaskOnly(invalidate: false)
        errorMessage = nil

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            recognitionRequest = request

            recognizedText = ""
            recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                // 回调在非主线程触发，跳回 MainActor 更新 UI；
                // generation 比对：若这轮已被 stop 作废，直接丢弃过期回调
                Task { @MainActor in
                    guard self.generation == token else { return }
                    if let result {
                        self.recognizedText = result.bestTranscription.formattedString
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        self.stop()
                    }
                }
            }

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            tapInstalled = true
            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
        } catch {
            errorMessage = "录音启动失败：\(error.localizedDescription)"
            stopTaskOnly()
        }
    }

    /// 停止录音并保留已识别文本（作废当前代际令牌，让在途回调失效）
    func stop() {
        stopTaskOnly()
    }

    /// 统一清理：停引擎、拆 tap、结束/取消识别请求与任务、释放音频会话。
    /// invalidate=false 表示只清理资源不换代（start 内部复用，避免提前作废自己）。
    private func stopTaskOnly(invalidate: Bool = true) {
        if invalidate { generation = UUID() }
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

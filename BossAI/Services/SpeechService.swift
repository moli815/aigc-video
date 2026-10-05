import Foundation
import Speech
import AVFoundation

/// 语音输入：原生 Speech 框架（zh-CN），识别文本实时回填输入框。
@MainActor
final class SpeechService: ObservableObject {
    @Published var isRecording = false
    @Published var recognizedText = ""
    @Published private(set) var isStarting = false
    private var tapInstalled = false
    private var generation = UUID()
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

    func stop() {
        stopTaskOnly()
    }

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

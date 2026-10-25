import Foundation
import SwiftData

// ============================================================================
// 文件职责：ChatViewModel 的会话删除入口（10-25）。
// 为什么单独成文件：ChatViewModel.swift 已是 God File，删除逻辑还要同时
// 处理「停流 / 级联删 / 复位 UI 状态」三件事，塞进主文件只会让它更难读。
// 真正的删除实现（本地级联 + 云端墓碑 + 离线补删）在 ConversationDeletion。
// ============================================================================

extension ChatViewModel {

    /// 删除当前会话（对话区内删除按钮的唯一入口）。
    ///
    /// 顺序有讲究：**先停流再删**——否则 runLoop 还在往一条已删除的会话里写消息，
    /// 会出现 SwiftData 写已删对象、脏数据回填、删完又冒出半条回复。
    ///
    /// - Returns: 是否真的删掉了（草稿态 / 已被别处删掉时返回 false）
    @discardableResult
    func deleteConversation() -> Bool {
        guard let conv = conversation else { return false }
        // 取消在途请求（不依赖 isStreaming 判断：任务可能正处于工具执行阶段）
        streamTask?.cancel()
        stop()

        let deleted = ConversationDeletion.delete(conv, context: modelContext)
        guard deleted else {
            errorMessage = "删除失败，请重试。"
            return false
        }
        // 复位所有与会话绑定的 UI 状态：不清会把上一条会话的流式缓冲/失败态带进下一条
        conversation = nil
        streamingText = ""
        streamingMessageId = nil
        statusText = nil
        pendingImage = nil
        partialSuccessMessage = nil
        failedUserMessageID = nil
        failedAssistantMessageID = nil
        suggestedFollowUps = []
        resumableTaskText = nil
        orderedMessageCount = -1
        requestMessageReload()
        toast = "对话已删除"
        return true
    }
}

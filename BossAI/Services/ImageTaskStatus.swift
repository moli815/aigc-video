import Foundation

// ============================================================================
// ImageTaskStatus.swift —— 图片任务「用户可见文案」唯一来源（2026-10-25 收口版）
//
// 为什么必须有这个文件：
//   之前状态与总结文案散落在 ChatViewModel+Streaming 的十几个分支里，
//   结果是模型的设计说明、prompt、"我做不到/去 Canva"、施工进度表全都漏进了聊天气泡。
//
// 现在**只允许**这五句话出现在界面和消息正文里（多一个字都不行）：
//   · 正在生成图片
//   · 正在处理图片
//   · 正在整理图片
//   · 图片已生成
//   · 图片生成失败，请重试
//   · 原图无法完整保留，请重新选择比例
//
// 硬规矩：
//   1. 这里不出现模型名、taskKind、prompt、requestId、字段名、百分比、预估耗时；
//   2. 阶段由**真实任务类型**决定，不用定时器轮播伪造进度；
//   3. 失败只给"能照做的下一步"，不解释技术原因。
// ============================================================================

enum ImageTaskStatus {

    /// 任务形态：决定用哪一句等待文案
    enum Kind: String, Equatable {
        /// 普通文生图
        case generate
        /// 参考图编辑（P 图、换背景、加人…）
        case edit
        /// 文字密集任务（无字底图 + 程序排版）
        case textOverlay = "text_overlay"
        /// 组图
        case series

        /// 等待中显示的那一句
        var waitText: String {
            switch self {
            case .generate:    return "正在生成图片"
            case .edit:        return "正在处理图片"
            case .textOverlay: return "正在整理图片"
            case .series:      return "正在生成图片"
            }
        }
    }

    /// 完成态（产物已落库）
    static let doneText = "图片已生成"

    /// 失败原因：只有两类对外文案（内部原因只进日志）
    enum Failure: Equatable {
        /// 上游/网络/参数/排版导致没出成品
        case generateFailed
        /// 输出与原始画布比例不一致（疑似裁切），本次结果不展示
        case aspectMismatch

        var message: String {
            switch self {
            case .generateFailed: return "图片生成失败，请重试"
            case .aspectMismatch: return "原图无法完整保留，请重新选择比例"
            }
        }
    }

    /// 等待文案（按任务形态）
    static func waitText(_ kind: Kind) -> String { kind.waitText }
}

/// 等待占位的状态：只有一个字段有意义 —— 当前该显示哪句话。
/// 保留 kind 而不是直接存字符串，是为了让"文案从哪来"始终可追溯。
struct ImageWaitState: Equatable {
    var kind: ImageTaskStatus.Kind

    var text: String { kind.waitText }
}

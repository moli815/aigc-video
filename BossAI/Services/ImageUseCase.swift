import Foundation
import UIKit

/// Image execution owns transport retries; the chat loop owns presentation only.
enum ImageUseCase {
    nonisolated static func visionCheck(imageData: Data, requirement: String) async -> (ok: Bool, note: String)? {
        let token: String? = await MainActor.run { HostedAccount.isHostedActive ? HostedAccount.shared.token : nil }
        guard let token, !token.isEmpty,
              let url = URL(string: AppConfig.hostedAPIBase + "/vision-check") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "image": "data:image/jpeg;base64," + imageData.base64EncodedString(),
            "question": "用户要求：\(String(requirement.prefix(200)))。生成的图片是否满足该要求？",
        ])
        // 10-23 P3：视觉校验请求体可能较大，响应为 small JSON；用 chatSession 给足 180s 并限制响应体 1MB
        guard let (data, resp) = try? await BoundedHTTPClient.data(for: req,
                                                                   session: BoundedHTTPClient.chatSession,
                                                                   limit: 1 * 1024 * 1024),
              resp.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (ok: (j["ok"] as? Bool) ?? true, note: (j["note"] as? String) ?? "")
    }


    static func generate(context: ImageRequestContext, service: ImageService) async throws -> Data {
        let limit = service.usesHostedIdempotency ? HostedAccount.cachedImageRetry : 0
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                return try await service.generate(prompt: context.prompt, references: context.references,
                    structured: context.structured, requestId: context.requestId,
                    layerDecomposition: context.layerDecomposition, renderIntent: context.renderIntent,
                    aspectRatio: context.aspectRatio, taskKind: context.taskKind,
                    qualityTier: context.qualityTier, requestedCount: context.requestedCount,
                    targetSize: context.targetSize, textMode: context.textMode == .overlay ? "overlay" : nil)
            } catch {
                // A direct provider has no documented idempotency guarantee. Do not retry
                // an unknown paid result just because a client-side timeout occurred.
                let cancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                let retryable = (error as? URLError) != nil || ((error as? ImageService.ImageError)?.isRetryable ?? false)
                guard !cancelled, retryable, attempt < limit else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
    }
    nonisolated static func aspectRatioValue(_ raw: String) -> CGFloat? {
        let parts = raw.split(separator: ":")
        guard parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite, width > 0, height > 0, (width / height).isFinite else { return nil }
        return CGFloat(width / height)
    }
    nonisolated static func generateSeriesWithRetry(prompt: String,
                                                    references: [Data],
                                                    service: ImageService,
                                                    requestedCount: Int,
                                                    structured: [String: Any]? = nil,
                                                    renderIntent: String? = nil,
                                                    aspectRatio: String? = nil,
                                                    qualityTier: String? = nil) async throws -> ImageService.SeriesOutcome {
        let idemKey = UUID().uuidString
        let limit = service.usesHostedIdempotency ? HostedAccount.cachedImageRetry : 0
        var attempt = 0
        while true {
            do {
                return try await service.generateSeries(prompt: prompt, requestId: idemKey,
                                                        requestedCount: requestedCount,
                                                        qualityTier: qualityTier,
                                                        aspectRatio: aspectRatio,
                                                        renderIntent: renderIntent,
                                                        structured: structured,
                                                        references: references)
            } catch {
                // 429/409（额度/进行中）不自动重试：重试只会再撞一次，交给用户决定
                let retryable = (error as? URLError) != nil
                    || ((error as? ImageService.ImageError)?.isRetryable ?? false)
                guard retryable, attempt < limit else { throw error }
                attempt += 1
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

}

import SwiftUI
import UIKit

// ============================================================================
// SeriesImageGrid.swift —— 组图逐张展示（10-24 新增，实施计划 §8.3.2）
//
// 职责：
//   1. 一条消息里的多张图按网格逐张展示，每张可点开预览、可单独保存；
//   2. 头部显示**真实**状态（已完成 X/N、失败序号），不虚构进度百分比；
//   3. "上游已生成但下载失败"单独提示，明确"不要重新生成"；
//   4. 列数按可用宽度自适应（iPad 横屏不会挤成一条），动态字体放大不截断状态文案。
//
// 性能：图片解码放在后台任务里做一次（Data → UIImage），不阻塞消息列表滚动。
// ============================================================================

struct SeriesImageGrid: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let messageID: UUID
    let meta: SeriesMeta
    /// 第 1 张（存在 Message.imageData）
    let firstImage: Data?
    /// 第 2 张起（Message.extraImagesJSON）
    let extraImagesJSON: Data?

    @State private var images: [UIImage] = []
    @State private var preview: SeriesPreviewPayload?

    private var columns: [GridItem] {
        // 134pt 是"能看清内容 + 三列在 iPhone 上也放得下"的经验值
        [GridItem(.adaptive(minimum: 134, maximum: 260), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if images.isEmpty {
                // 解码中或全部解码失败：给静态占位，不画无限动画
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.surface.opacity(0.5))
                    .overlay(
                        Text(meta.succeeded > 0 ? "正在读取图片…" : "没有可显示的图片")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    )
                    .frame(height: 120)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    // 用 indices + id: \.self：序号与图片一一对应，不依赖枚举元组
                    ForEach(images.indices, id: \.self) { idx in
                        let image = images[idx]
                        Button {
                            preview = SeriesPreviewPayload(image: image, index: idx + 1)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(minWidth: 0, maxWidth: .infinity)
                                    .frame(height: 150)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(theme.border, lineWidth: 0.6)
                                    )
                                // 序号角标：让"哪张是哪张"和失败序号能对上
                                Text("#\(idx + 1)")
                                    .font(.system(size: 10, weight: .semibold).monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.black.opacity(0.45), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(6)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(idx + 1) 张图片，点按查看大图")
                    }
                }
                .transition(reduceMotion ? .identity : .opacity)
            }

            if !meta.downloadFailedIndices.isEmpty {
                Text("第 \(meta.downloadFailedIndices.map { "#\($0)" }.joined(separator: "、")) 张已生成，但没能下载到这台设备。不用重新生成，稍后重新保存即可。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: messageID) { await decode() }
        .fullScreenCover(item: $preview) { payload in
            SeriesImagePreview(payload: payload)
        }
        .accessibilityIdentifier("series-grid")
    }

    /// 状态行：只用服务端给的真实数字
    private var header: some View {
        HStack(spacing: 8) {
            if !meta.statusLine.isEmpty {
                Text(meta.statusLine)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(meta.failedIndices.isEmpty ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if meta.partial {
                Text("部分成功")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.orange.opacity(0.16), in: Capsule())
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
    }

    private func decode() async {
        let first = firstImage
        let extra = extraImagesJSON
        // Data 是 Sendable：在后台只做解码，回到主线程再构造 UIImage 数组
        let blobs: [Data] = await Task.detached(priority: .userInitiated) {
            var all: [Data] = []
            if let first { all.append(first) }
            if let extra, let arr = try? JSONDecoder().decode([Data].self, from: extra) {
                all.append(contentsOf: arr)
            }
            return all
        }.value
        guard !Task.isCancelled else { return }
        images = blobs.compactMap { UIImage(data: $0) }
    }
}

// MARK: - 大图预览

struct SeriesPreviewPayload: Identifiable {
    let id = UUID()
    let image: UIImage
    let index: Int
}

struct SeriesImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let payload: SeriesPreviewPayload
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: payload.image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("第 \(payload.index) 张")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(payload.image, nil, nil, nil)
                        saved = true
                    } label: {
                        Label(saved ? "已保存" : "保存原图",
                              systemImage: saved ? "checkmark.circle" : "square.and.arrow.down")
                    }
                    .disabled(saved)
                }
            }
            .preferredColorScheme(.dark)
        }
    }
}

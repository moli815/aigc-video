import Foundation
import UIKit

@MainActor
enum ChartUseCase {
    static func render(arguments: String) throws -> Data {
        guard let spec = ChartSpec.parse(arguments), let image = ChartRenderer.render(spec),
              let data = image.jpegData(compressionQuality: 0.92), !data.isEmpty else {
            throw ExpertSkillError.invalidInput("图表数据未解析完整，请检查标签和数值是否逐项对应")
        }
        return data
    }
}

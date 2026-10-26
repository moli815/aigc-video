import Foundation

/// A compact planning skill, applied once before tool selection. Research and provenance:
/// docs/image/2026-10-26-design-pipeline.md. User requirements always outrank defaults.
enum ImageDesignGuidance {
    static let instructions = """
    图片设计方法：调用工具前在内部完成简短设计判断，不把过程写成一大段让用户反复选方案。
    1. 先确定用途、受众、用户指定风格及禁止项，选一个清晰视觉方向。用户说动漫就明确线稿、色块、角色/场景表现；不要自动套蓝色霓虹城市、发光图标或玻璃科技风。
    2. 画面只有一个主视觉焦点，主次通过大小、位置、明暗形成。使用连贯配色与有意的留白；视觉元素服务主题，不为显得丰富而堆装饰。
    3. 有文字时先规划标题、副标题、正文、联系方式的阅读顺序和对齐关系。标题应明显大于正文，重要信息不能塞成左上角小字。图像主体与文字区域错开，避免压住人脸或关键信息。
    4. structured.text 按语义逐项保存精确原文，key 唯一稳定；不能把构图指令、负面约束或内部分析当正文。信息必须完整，不编造姓名、电话或宣传事实。
    5. structured.layout 可选 editorial/centered/split 构图；需要自由排布时为每个 key 给出归一化 blocks（0到1），完整覆盖所有文字、留足边距、不重叠。不要给每项都相同坐标。
    6. prompt 用具体主体、构图、风格表现、材质和光线描述画面，明确用户要求改变什么、保留什么；少用空泛的高级/震撼/精美形容词。文字原文放 structured.text。新风格优先于参考图旧风格，用户明确否定的风格不能继续沿用。
    """
}

import Foundation

/// 发布就绪清单：**Implementation Plan §34 Phase 30 Release Preparation 的代码化版本**。
///
/// 为什么清单要进代码而不是留在文档里：
/// 文档里的 checklist 会被打勾，然后开始撒谎——下一版改了代码，勾还在。
/// 这里把每一条变成**可执行或不执行都明确**的条目：
/// - 能自动验证的（`automated`）由 `ReleaseReadinessRunner` 真跑，每次结果都是新鲜的；
/// - 只能人工/实机验证的（`manual`）列出具体怎么做，谁验谁负责，不假装通过。
///
/// 这里有一条原则：**宁可写成 manual，也不要写一个永远返回 true 的自动检查**。
public enum ReleaseChecklist {

    /// 所属类别，与 §34 的小节一一对应。
    public enum Category: String, Codable, Sendable, CaseIterable {
        case build
        case ai
        case audio
        case data
        case performance
        case privacy

        public var displayName: String {
            switch self {
            case .build: "构建"
            case .ai: "模型"
            case .audio: "音频"
            case .data: "数据"
            case .performance: "性能"
            case .privacy: "隐私"
            }
        }
    }

    /// 一条检查项。
    public struct Item: Identifiable, Sendable, Hashable {
        public let id: String
        public let title: String
        public let category: Category
        /// 人工怎么验：要跑什么命令、看什么现象、判定标准是什么。
        public let guidance: String
        /// true = 有自动检查实现，Runner 必须给出结果（没实现就是 bug，而非跳过）。
        public let automated: Bool

        public init(id: String, title: String, category: Category, guidance: String, automated: Bool) {
            self.id = id
            self.title = title
            self.category = category
            self.guidance = guidance
            self.automated = automated
        }
    }

    public static let items: [Item] = [
        // MARK: Build
        Item(
            id: "build.clean",
            title: "干净构建通过",
            category: .build,
            guidance: "rm -rf .build && swift build --disable-sandbox；CI 里建议一并验证。",
            automated: false
        ),
        Item(
            id: "build.release",
            title: "Release 构建与打包签名通过",
            category: .build,
            guidance: "swift build -c release --disable-sandbox && bash Scripts/make_app.sh --no-build && codesign --verify --deep --strict dist/AI_Language_Coach.app",
            automated: false
        ),
        Item(
            id: "build.noDebugDependency",
            title: "无仅调试用依赖（无本地路径依赖 / 无 unsafeFlags）",
            category: .build,
            guidance: "检查 Package.swift：不得出现 .package(path:) 等本地路径依赖，也不得为图省事开 unsafeFlags。",
            automated: true
        ),
        Item(
            id: "build.noHardcodedPaths",
            title: "源码无硬编码本机路径 / 端口",
            category: .build,
            guidance: "架构红线：Hard-coded model path、Hard-coded localhost port 都是明令禁止的；端点与端口只能来自配置。",
            automated: true
        ),
        Item(
            id: "build.noUnusableOverlay",
            title: "未使用本工程不可用的 SwiftUI 跨导入叠加 API",
            category: .build,
            guidance: "SwiftPM 对 cross-import overlay 支持不完整：这类 API 编译通过、启动即崩（真机跑一次才发现）。视频请用 AppKit 的 AVPlayerView 包一层，不要用叠加里的 VideoPlayer。",
            automated: true
        ),

        // MARK: AI
        Item(
            id: "ai.healthCheck",
            title: "供应商健康检查可用",
            category: .ai,
            guidance: "在「设置 → 模型管理」对每个供应商点一次健康检查：本地 runtime 未启动时应明确报「未运行」而不是假 healthy。",
            automated: false
        ),
        Item(
            id: "ai.modelLoading",
            title: "模型加载 / 卸载可用",
            category: .ai,
            guidance: "本地模型点「启动」后对话能出内容；点「停止」后 Ollama 侧显存应释放（ollama ps 看不到该模型）。",
            automated: false
        ),
        Item(
            id: "ai.modelUnloading",
            title: "空闲与内存压力下的自动挂起可用",
            category: .ai,
            guidance: "第 27 步：配置 resource_policy 的空闲阈值，长时间不用后该能力被挂起；再次使用应自动恢复且不影响回复。",
            automated: false
        ),
        Item(
            id: "ai.fallback",
            title: "兜底链路可用（老师必回）",
            category: .ai,
            guidance: "拔掉本地 runtime 的网络或 kill 掉进程后发消息，应当得到明确提示而非转圈到底。",
            automated: false
        ),
        Item(
            id: "ai.unsupportedCapability",
            title: "核心能力都有已启用的供应商（不支持的能力有明确口径）",
            category: .ai,
            guidance: "对话 / 识别 / 朗读必须各有一个默认启用的供应商；纯算法能力（VAD / 发音评测）不走供应商，界面要写明「由本地算法提供」。",
            automated: true
        ),

        // MARK: Audio
        Item(
            id: "audio.permission",
            title: "麦克风权限流程正常",
            category: .audio,
            guidance: "首次点语音输入的授权弹窗 → 拒绝后给出「去系统设置开启」的引导；授权后能录音。",
            automated: false
        ),
        Item(
            id: "audio.recording",
            title: "录音稳定（无爆音截断 / 无限增长）",
            category: .audio,
            guidance: "连续说 30 秒以上，观察 VAD 分段与内存占用是否平稳。",
            automated: false
        ),
        Item(
            id: "audio.playback",
            title: "播放稳定（整段与首句即播都正常）",
            category: .audio,
            guidance: "本地长句朗读：应在合成出首句后立刻出声，后续句子不断顿。",
            automated: false
        ),
        Item(
            id: "audio.noDeadlock",
            title: "流式链路不死锁",
            category: .audio,
            guidance: "边说边识别 + 边合成边播同时进行 3 分钟，界面不卡死、能随时中断。",
            automated: false
        ),

        // MARK: Data
        Item(
            id: "data.migration",
            title: "数据库迁移可用且幂等",
            category: .data,
            guidance: "从空库反复初始化到最新 schemaVersion；重复迁移不得报错或改坏数据。",
            automated: true
        ),
        Item(
            id: "data.backupExport",
            title: "备份 / 导出行为已定义且可用",
            category: .data,
            guidance: "设置页导出备份 → 得到包含学习库（含 -wal）、配置与留痕的时间戳 zip。",
            automated: true
        ),
        Item(
            id: "data.corruptedHandled",
            title: "损坏数据被妥善隔离而非沉默丢失",
            category: .data,
            guidance: "把 learning.db 换成随机字节后启动：应隔离原文件（不删除）、自动重建并向用户说明，而不是静默关闭持久化。",
            automated: true
        ),

        // MARK: Performance
        Item(
            id: "perf.memoryBench",
            title: "内存基准已完成",
            category: .performance,
            guidance: "swift run alc-bench；产物落在 .workbuddy/benchmark/latest.json（含内存采样字段）。",
            automated: true
        ),
        Item(
            id: "perf.latencyBench",
            title: "时延基准已完成",
            category: .performance,
            guidance: "同上，latest.json 应含 LLM 时延条目（TTFT / tokens-per-second）。",
            automated: true
        ),
        Item(
            id: "perf.longSession",
            title: "长会话测试已通过",
            category: .performance,
            guidance: "连续对话 30 分钟以上：内存不持续增长、滚动不卡顿、回声课堂教学仍然可用。",
            automated: false
        ),

        // MARK: Privacy
        Item(
            id: "privacy.noUnintendedNetwork",
            title: "无非预期的网络请求",
            category: .privacy,
            guidance: "默认配置必须是纯本地；源码不得出现遥测/统计域名或上报代码。",
            automated: true
        ),
        Item(
            id: "privacy.noAudioInLogs",
            title: "日志不含音频内容",
            category: .privacy,
            guidance: "AppLog 调用点不得把音频缓冲/PCM 数据拼进日志——只能有长度或体积。",
            automated: true
        ),
        Item(
            id: "privacy.storageDocumented",
            title: "本地存储位置有清单",
            category: .privacy,
            guidance: "「设置 → 隐私与安全」要列出学习库 / 配置 / 留痕的实际路径（日志须注明不落盘）。",
            automated: true
        ),
    ]

    public static func item(id: String) -> Item? { items.first { $0.id == id } }
}

/// 一条检查的结论。
public struct ReleaseCheckResult: Identifiable, Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case passed
        case failed(String)
        /// 只能人工验证。**不是通过**，也不是未知——需要有人去跑 `item.guidance`。
        case manual

        public var isPassed: Bool {
            if case .passed = self { return true }
            return false
        }
    }

    public let item: ReleaseChecklist.Item
    public let status: Status

    public init(item: ReleaseChecklist.Item, status: Status) {
        self.item = item
        self.status = status
    }

    public var id: String { item.id }
}

/// 一次发布就绪检查的完整结论。
public struct ReleaseReadinessReport: Sendable {
    public static let schemaVersion = 1

    public let generatedAt: Date
    public let results: [ReleaseCheckResult]

    public init(generatedAt: Date = Date(), results: [ReleaseCheckResult]) {
        self.generatedAt = generatedAt
        self.results = results
    }

    public var passedCount: Int { results.filter(\.status.isPassed).count }
    public var failedResults: [ReleaseCheckResult] {
        results.filter {
            if case .failed = $0.status { return true }
            return false
        }
    }
    public var manualResults: [ReleaseCheckResult] {
        results.filter {
            if case .manual = $0.status { return true }
            return false
        }
    }

    /// 能不能发：**自动检查全绿**（人工项不算通过，但也不拦发布——它们是「待办」而非「缺陷」）。
    public var isReleaseReady: Bool { failedResults.isEmpty }

    /// Markdown 摘要（写进 PR / Release notes 里）。
    public func markdownSummary() -> String {
        var lines: [String] = ["# 发布就绪检查", ""]
        lines.append("时间：\(Self.stamp(generatedAt))")
        lines.append("自动检查：\(passedCount) 通过 · \(failedResults.count) 未通过 · \(manualResults.count) 待人工验证")
        lines.append("结论：**\(isReleaseReady ? "可以发布" : "存在未通过项，禁止发布")**")
        lines.append("")

        for category in ReleaseChecklist.Category.allCases {
            let group = results.filter { $0.item.category == category }
            guard !group.isEmpty else { continue }
            lines.append("## \(category.displayName)")
            lines.append("")
            for result in group {
                switch result.status {
                case .passed:
                    lines.append("- [x] \(result.item.title)")
                case .manual:
                    lines.append("- [ ] \(result.item.title) — 待人工验证：\(result.item.guidance)")
                case .failed(let reason):
                    lines.append("- [ ] \(result.item.title) — **未通过**：\(reason)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

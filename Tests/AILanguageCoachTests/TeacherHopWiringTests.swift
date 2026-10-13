import XCTest

/// 老师「跳一跳」的接线哨兵（2026-10-13 用户报障：老师从早跳到晚、幅度过大、
/// 「眼睛不动身体动」观感诡异）。
///
/// 期望行为（用户原话：「老师应该是不跳动的，只眨眼和挥动教棒，
/// 只有完成今日任务才会跳」）：
/// - **平时**：每一处老师渲染都关掉常驻浮动（`bobbing: false`）；
/// - **今日任务全完成**：`TeacherCorner` 把庆祝 tick 喂给 `CuteAnimalView.hopTick`，
///   老师跳一下（emphasis 档，一天一次）。
///
/// 反证方式（四条都真跑过，红在该红的断言上）：
/// ① 删 `TeacherCorner` 座位那处 `bobbing: false` → `testTeacherSeatDoesNotIdleHop` 红；
/// ② 删 ChatView 头部那处 `bobbing: false` → `testNoTeacherRenderingIdleHops` 红；
/// ③ 删 `isCelebrating → hopTick` 的接线 → `testCelebrationTriggersTheHop` 红；
/// ④ 删 `CuteAnimalView` 的 hopTick 处理 → `testHopIsGuardedForSleepingAndFixtures` 红。
final class TeacherHopWiringTests: XCTestCase {

    // MARK: - ① 座位：平时不跳

    /// 侧栏座位那只老师（84pt，用户天天看的那只）必须关掉常驻浮动，
    /// 并且把庆祝 tick 接上 —— 少任何一半这串调用形态都红。
    func testTeacherSeatDoesNotIdleHop() throws {
        let normalized = try Self.code("Sources/AppUI/Components/TeacherCorner.swift")
        XCTAssertTrue(
            normalized.contains(
                "accessory: .teacher, bobbing: false, knockTick: knockTick, hopTick: hopTick"
            ),
            "老师座位的 CuteAnimalView 调用少了 bobbing: false / hopTick —— 老师又会从早跳到晚"
        )
    }

    // MARK: - ② 庆祝才跳

    /// 今日任务全完成 → 跳一下。两条路都要有：
    /// 已挂载时靠 `onChange(of: isCelebrating)`；庆祝**之后**才挂上来（侧栏被
    /// `celebrateToday` 拉开）靠 `onAppear` 补跳 —— 只钉一条，另一条被删时测试全绿。
    func testCelebrationTriggersTheHop() throws {
        let normalized = try Self.code("Sources/AppUI/Components/TeacherCorner.swift")
        XCTAssertTrue(
            normalized.contains(
                "onChange(of: isCelebrating) { _, celebrating in if celebrating { hopTick += 1 } }"
            ),
            "庆祝进行中（视图已挂载）时没人给 hopTick 加一 —— 今日全完成老师不会跳"
        )
        XCTAssertTrue(
            normalized.contains(
                "onAppear { if isExpanded { announceBoard() } if isCelebrating { hopTick += 1 } }"
            ),
            "庆祝之后才挂载的座位不会补跳 —— 侧栏被庆祝拉开时那一下跳就丢了"
        )
    }

    // MARK: - ③ 跳动本体的形状

    /// 参数存在、init 真赋值（漏赋值是静默的：成员有默认值，编译通过、行为归零）。
    func testHopParameterExistsAndIsAssignedInInit() throws {
        let normalized = try Self.code("Sources/AppUI/Theme/Animals.swift")
        XCTAssertTrue(normalized.contains("public var hopTick: Int = 0"),
                      "CuteAnimalView 少了 hopTick 参数")
        XCTAssertTrue(normalized.contains("self.hopTick = hopTick"),
                      "init 漏了 hopTick 赋值 —— 静默归零，庆祝永远不跳")
    }

    /// 睡着不跳（Zzz 会脱离身体）、渲染夹具关着动画也不跳（否则确定性出图全毁）。
    func testHopIsGuardedForSleepingAndFixtures() throws {
        let normalized = try Self.code("Sources/AppUI/Theme/Animals.swift")
        XCTAssertTrue(normalized.contains("onChange(of: hopTick) { _, tick in"),
                      "hopTick 没有 onChange 处理 —— 传了也白传")
        XCTAssertTrue(
            normalized.contains("guard tick > 0, !isSleeping, Self.animationsEnabled else { return }"),
            "庆祝跳少了守卫：睡着的老师会跳（Zzz 脱离身体）、渲染夹具会被跳成不确定"
        )
    }

    /// 跳用的是 emphasis 档（全项目唯一允许过冲的曲线，「里程碑」专用），
    /// 且走**独立**的 offset —— 不与常驻浮动互相打断。
    func testHopUsesTheEmphasisTokenOnItsOwnOffset() throws {
        let normalized = try Self.code("Sources/AppUI/Theme/Animals.swift")
        XCTAssertTrue(normalized.contains(".offset(y: hopLift)"),
                      "庆祝跳没有独立的 offset —— 会和常驻浮动缠在一起")
        XCTAssertTrue(
            normalized.contains("withAnimation(motion.animation(.emphasis)) { hopLift = -size * 0.22 }"),
            "起跳不是 emphasis 档 / 幅度变了 —— 庆祝这一刻的曲线全项目只此一处"
        )
        XCTAssertTrue(
            normalized.contains("withAnimation(motion.animation(.emphasis)) { hopLift = 0 }"),
            "落回没有用 emphasis 档 —— 起跳和落地会是两种手感"
        )
    }

    // MARK: - ④ 全仓扫描：一处老师渲染都不许带常驻浮动

    /// 老师头像有 7 处（侧栏座位 / 侧栏收起态 / 聊天头部 / 思考中×3 / 每条老师回复 /
    /// 准备卡）。逐个钉字符串既啰嗦又漏得起，这里按「kind 是老师」扫全仓：
    /// 新加一处漏关 `bobbing`，这条用例当场红。
    ///
    /// ⚠️ 座位那只用的是 `kind: kind`（视图自己的属性），扫不出来 —— 由
    /// `testTeacherSeatDoesNotIdleHop` 单独钉，两条互补。
    func testNoTeacherRenderingIdleHops() throws {
        var checked = 0
        for path in try Self.sourceFiles() {
            let normalized = try Self.code(path)
            // 按调用点切开，逐段取参数表（括号配对，容忍参数里出现括号）。
            for chunk in normalized.components(separatedBy: "CuteAnimalView(").dropFirst() {
                guard let args = Self.callArguments(in: chunk) else { continue }
                let isTeacher = args.contains("kind: teacherKind")
                    || args.contains("kind: state.teacherAnimalKind")
                guard isTeacher else { continue }
                checked += 1
                XCTAssertTrue(
                    args.contains("bobbing: false"),
                    "\(path) 里的老师渲染没关常驻浮动 —— 老师平时不跳，只眨眼和挥教棍"
                )
            }
        }
        XCTAssertGreaterThanOrEqual(
            checked, 7,
            "扫到的老师渲染少于 7 处 —— 扫描器本身坏了（marker 关键字被改？先修扫描器）"
        )
    }

    // MARK: - 工装

    /// 读源码做哨兵：去掉纯注释行（注释里的同款字串会造成假绿），
    /// 再把所有空白压成单个空格 —— 多行调用形态就能当一整串钉。
    private static func code(_ path: String) throws -> String {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        return raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// `Sources` 下全部 swift 文件（相对仓库根 —— 与其它哨兵测试同一假设）。
    private static func sourceFiles() throws -> [String] {
        var files: [String] = []
        var pending = ["Sources"]
        while let dir = pending.popLast() {
            for entry in try FileManager.default.contentsOfDirectory(atPath: dir) {
                let path = "\(dir)/\(entry)"
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                    if isDirectory.boolValue {
                        pending.append(path)
                    } else if entry.hasSuffix(".swift") {
                        files.append(path)
                    }
                }
            }
        }
        return files
    }

    /// 从「`CuteAnimalView(` 之后」的片段里，按括号配对取出整个参数表。
    private static func callArguments(in chunk: String) -> String? {
        var depth = 0
        for index in chunk.indices {
            switch chunk[index] {
            case "(": depth += 1
            case ")":
                if depth == 0 { return String(chunk[chunk.startIndex..<index]) }
                depth -= 1
            default: break
            }
        }
        return nil
    }
}

import AIDomain
@testable import AIDomain
import XCTest

/// #229 能力定位（placement）：
/// - 样本不足 → `level == nil`（还在观察中），绝不硬给档位；
/// - 样本充足 → 档位、依据、距下一档的 gap 齐全；
/// - 分段线性刻度与档位分界的行为钉死。
final class PlacementTests: XCTestCase {

    private func skill(_ kind: SkillKind, score: Double, samples: Int) -> SkillScore {
        SkillScore(kind: kind, score: score, sampleCount: samples, detail: "")
    }

    func testInsufficientSamplesMeansStillObserving() {
        // 新学员：聊了 5 轮、3 个词 → 不给档位。
        let estimate = PlacementEstimator.estimate(
            skills: [skill(.grammar, score: 0.8, samples: 5)],
            totalMessages: 5, activeDays: 1, vocabularyCount: 3, masteredCount: 0
        )
        XCTAssertFalse(estimate.isConfident)
        XCTAssertNil(estimate.level)
        XCTAssertFalse(estimate.signals.isEmpty)
    }

    func testLowActivityBeginnerMapsToA1() {
        // 聊得不少但批注很密、词很少、没发音 → A1。
        let estimate = PlacementEstimator.estimate(
            skills: [
                skill(.grammar, score: 0.1, samples: 30),
                skill(.vocabulary, score: 0.1, samples: 30),
            ],
            totalMessages: 30, activeDays: 4, vocabularyCount: 25, masteredCount: 2
        )
        XCTAssertTrue(estimate.isConfident)
        XCTAssertEqual(estimate.level, .a1)
        XCTAssertEqual(estimate.nextLevel, .a2)
        XCTAssertFalse(estimate.gaps.isEmpty)
    }

    func testStrongLearnerMapsToB1OrAbove() {
        // 批注稀、词量 800+、开口 120+、发音好 → B1 / B2。
        let estimate = PlacementEstimator.estimate(
            skills: [
                skill(.grammar, score: 0.9, samples: 120),
                skill(.vocabulary, score: 0.8, samples: 120),
                skill(.pronunciation, score: 0.85, samples: 20),
                skill(.fluency, score: 0.8, samples: 20),
            ],
            totalMessages: 130, activeDays: 20, vocabularyCount: 900, masteredCount: 400
        )
        XCTAssertTrue(estimate.isConfident)
        XCTAssertEqual(estimate.level, .b2)
        XCTAssertNil(estimate.nextLevel)
    }

    func testVocabularyScaleIsPiecewiseLinear() {
        XCTAssertEqual(PlacementEstimator.piecewise(PlacementEstimator.vocabularyScale, value: 0), 0)
        XCTAssertEqual(PlacementEstimator.piecewise(PlacementEstimator.vocabularyScale, value: 120), 0.25)
        // 235 介于 120（0.25）与 350（0.5）之间 → 0.25 + (115/230)*0.25 = 0.375。
        XCTAssertEqual(PlacementEstimator.piecewise(PlacementEstimator.vocabularyScale, value: 235), 0.375, accuracy: 0.0001)
        XCTAssertEqual(PlacementEstimator.piecewise(PlacementEstimator.vocabularyScale, value: 5000), 1)
    }

    func testMissingDimensionsDoNotDragScore() {
        // 只有语法有样本、其他全缺：不该因为「发音 0 分」把总分拖到地板。
        let estimate = PlacementEstimator.estimate(
            skills: [skill(.grammar, score: 0.9, samples: 40)],
            totalMessages: 40, activeDays: 5, vocabularyCount: 0, masteredCount: 0
        )
        XCTAssertTrue(estimate.score > 0.3)
        // 没跟读评测要如实说出来。
        XCTAssertTrue(estimate.signals.contains("还没有跟读评测"))
    }

    func testEmptyEverythingIsStillObservable() {
        let estimate = PlacementEstimator.estimate(
            skills: [], totalMessages: 0, activeDays: 0, vocabularyCount: 0, masteredCount: 0
        )
        XCTAssertNil(estimate.level)
        XCTAssertFalse(estimate.isConfident)
    }
}

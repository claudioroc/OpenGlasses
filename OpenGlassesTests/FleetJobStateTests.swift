import XCTest
@testable import OpenGlasses

final class FleetJobStateTests: XCTestCase {
    func testQueuedMayStartCancelOrFail() {
        XCTAssertTrue(FleetJobTransition.canMove(from: .queued, to: .running))
        XCTAssertTrue(FleetJobTransition.canMove(from: .queued, to: .cancelled))
        XCTAssertTrue(FleetJobTransition.canMove(from: .queued, to: .failed))
        XCTAssertFalse(FleetJobTransition.canMove(from: .queued, to: .succeeded))
    }

    func testRunningMayWaitForApproval() {
        XCTAssertTrue(FleetJobTransition.canMove(from: .running, to: .awaitingApproval))
        XCTAssertTrue(FleetJobTransition.canMove(from: .awaitingApproval, to: .running))
        XCTAssertFalse(FleetJobTransition.canMove(from: .awaitingApproval, to: .succeeded))
    }

    func testTerminalPhasesAreFrozen() {
        for phase in [FleetJobPhase.succeeded, .failed, .cancelled] {
            XCTAssertTrue(phase.isTerminal)
            XCTAssertFalse(phase.isCancellable)
            XCTAssertTrue(FleetJobTransition.allowedMoves(from: phase).isEmpty)
            XCTAssertFalse(FleetJobTransition.canMove(from: phase, to: .running))
        }
    }

    func testApplyUpdatesTimestampAndRejectsIllegalHop() throws {
        let job = FleetSiriFixtures.job(phase: .queued)
        let next = try FleetJobTransition.apply(
            job,
            to: .running,
            at: Date(timeIntervalSince1970: 99),
            spokenSummary: "Running."
        )
        XCTAssertEqual(next.phase, .running)
        XCTAssertEqual(next.updatedAt.timeIntervalSince1970, 99)
        XCTAssertEqual(next.spokenSummary, "Running.")

        XCTAssertThrowsError(try FleetJobTransition.apply(job, to: .succeeded)) { error in
            guard case FleetJobTransitionError.illegal(let from, let to) = error else {
                return XCTFail("expected illegal transition, got \(error)")
            }
            XCTAssertEqual(from, .queued)
            XCTAssertEqual(to, .succeeded)
        }
    }

    func testIdentityIsStableAcrossTransition() throws {
        let job = FleetSiriFixtures.job(id: "stable-id")
        let next = try FleetJobTransition.apply(job, to: .running)
        XCTAssertEqual(next.id, "stable-id")
        XCTAssertEqual(next.title, job.title)
        XCTAssertEqual(next.domain, .os)
    }
}

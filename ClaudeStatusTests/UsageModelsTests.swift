import Foundation
import XCTest
@testable import ClaudeStatus

final class UsageModelsTests: XCTestCase {
    func testDecodesCompletePayloadAndIgnoresUnknownFields() throws {
        let data = Data(
            """
            {
              "five_hour": {"utilization": 14.2, "resets_at": "2026-07-16T12:00:00.123Z"},
              "seven_day": {"utilization": 2, "resets_at": "2026-07-21T22:59:00Z"},
              "seven_day_sonnet": {"utilization": 7.5, "resets_at": null},
              "seven_day_opus": {"utilization": 31, "resets_at": "2026-07-20T10:30:00Z"},
              "future_field": {"value": true}
            }
            """.utf8
        )

        let payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        let snapshot = payload.snapshot(fetchedAt: Date(timeIntervalSince1970: 123))

        XCTAssertEqual(snapshot.currentSession?.utilization, 14.2)
        XCTAssertEqual(snapshot.weeklyAllModels?.utilization, 2)
        XCTAssertEqual(snapshot.weeklySonnet?.utilization, 7.5)
        XCTAssertNil(snapshot.weeklySonnet?.resetsAt)
        XCTAssertEqual(snapshot.weeklyOpus?.utilization, 31)
        XCTAssertTrue(snapshot.hasAnyLimit)
    }

    func testDecodesPartialPayload() throws {
        let data = Data(#"{"five_hour":{"utilization":42,"resets_at":null}}"#.utf8)
        let payload = try JSONDecoder().decode(UsagePayload.self, from: data)
        let snapshot = payload.snapshot(fetchedAt: Date())

        XCTAssertEqual(snapshot.currentSession?.utilization, 42)
        XCTAssertNil(snapshot.weeklyAllModels)
        XCTAssertNil(snapshot.weeklySonnet)
        XCTAssertNil(snapshot.weeklyOpus)
    }

    func testUtilizationIsClamped() {
        XCTAssertEqual(LimitWindow(utilization: -3, resetsAt: nil).utilization, 0)
        XCTAssertEqual(LimitWindow(utilization: 101, resetsAt: nil).utilization, 100)
        XCTAssertEqual(LimitWindow(utilization: .infinity, resetsAt: nil).utilization, 0)
    }

    func testMissingUtilizationIsRejected() {
        let data = Data(#"{"five_hour":{"resets_at":null}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(UsagePayload.self, from: data))
    }

    func testCredentialPlanNameMapping() {
        XCTAssertEqual(KeychainCredentialProvider.planName(subscriptionType: "max"), "Max")
        XCTAssertEqual(KeychainCredentialProvider.planName(subscriptionType: "PRO"), "Pro")
        XCTAssertNil(KeychainCredentialProvider.planName(subscriptionType: "unknown"))
    }

    func testExtractsOnlyCurrentClaudeCodeCredentialPayload() throws {
        let data = Data(
            #"{"claudeAiOauth":{"accessToken":"current-token","refreshToken":"refresh","subscriptionType":"max"}}"#.utf8
        )

        let credential = try XCTUnwrap(KeychainCredentialProvider.credential(in: data))
        XCTAssertEqual(credential.accessToken, "current-token")
        XCTAssertEqual(credential.planName, "Max")
    }

    func testRejectsLegacyCredentialPayloadInsteadOfSearchingRecursively() {
        let data = Data(#"{"oauth":{"tokens":{"access_token":"legacy-token"}}}"#.utf8)

        XCTAssertNil(KeychainCredentialProvider.credential(in: data))
    }

    func testRejectsDecoyAccessTokenOutsideExpectedObject() {
        let data = Data(
            #"{"accessToken":"decoy","nested":{"claudeAiOauth":{"accessToken":"also-decoy"}}}"#.utf8
        )

        XCTAssertNil(KeychainCredentialProvider.credential(in: data))
    }

    func testRejectsCredentialTokenContainingControlCharacters() {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"token\nleak"}}"#.utf8)

        XCTAssertNil(KeychainCredentialProvider.credential(in: data))
    }
}

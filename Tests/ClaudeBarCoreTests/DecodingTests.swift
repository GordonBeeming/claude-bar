import Testing
import Foundation
@testable import ClaudeBarCore

struct DecodingTests {
    private let realPayload = """
    {"limits":[
     {"kind":"session","group":"session","percent":11,"severity":"normal","resets_at":"2026-07-07T06:20:00.010527+00:00","scope":null,"is_active":false},
     {"kind":"weekly_all","group":"weekly","percent":89,"severity":"warning","resets_at":"2026-07-08T07:00:00.010549+00:00","scope":null,"is_active":true},
     {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-07-08T07:00:00.010825+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
    ]}
    """

    @Test func decodesRealPayloadShape() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(realPayload.utf8))
        #expect(response.limits.count == 3)

        let session = response.limits[0]
        #expect(session.kind == "session")
        #expect(session.percent == 11)
        #expect(session.severity == .normal)
        #expect(session.resetsAt != nil)
        #expect(session.isActive == false)

        let weeklyAll = response.limits[1]
        #expect(weeklyAll.percent == 89)
        #expect(weeklyAll.severity == .warning)
        #expect(weeklyAll.resetsAt != nil)
        #expect(weeklyAll.isActive == true)

        let weeklyScoped = response.limits[2]
        #expect(weeklyScoped.percent == 0)
        #expect(weeklyScoped.severity == .normal)
        #expect(weeklyScoped.resetsAt != nil)
        // Unknown keys nested inside `scope` (e.g. "surface") must not break decoding.
        #expect(weeklyScoped.scope?.model?.displayName == "Fable")
    }

    @Test func unknownKindAndSeverityDegradeGracefully() throws {
        let json = """
        {"limits":[
         {"kind":"lunar_cycle","group":"other","percent":42,"severity":"apocalyptic","resets_at":null,"scope":null,"is_active":false}
        ]}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.limits.count == 1)
        #expect(response.limits[0].kind == "lunar_cycle")
        #expect(response.limits[0].severity == .normal)
        #expect(response.limits[0].resetsAt == nil)
    }

    @Test func missingResetsAtDecodesToNilDate() throws {
        let json = """
        {"limits":[
         {"kind":"session","group":"session","percent":11,"severity":"normal","scope":null,"is_active":false}
        ]}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.limits[0].resetsAt == nil)
    }

    @Test func unknownTopLevelKeysAreIgnored() throws {
        let json = """
        {"limits":[
         {"kind":"session","group":"session","percent":11,"severity":"normal","resets_at":null,"scope":null,"is_active":false}
        ],"account_id":"abc123","extra":{"nested":true}}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.limits.count == 1)
    }
}

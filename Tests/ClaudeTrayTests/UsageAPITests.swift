import Foundation
import Testing
@testable import ClaudeTray

@Suite struct UsageAPIParsingTests {
    let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)

    /// Trimmed from a real response for an account without a session limit (2026-11-03).
    let noSessionLimit = Data("""
    {"five_hour":null,
     "seven_day":{"utilization":40.0,"resets_at":"2026-11-04T10:00:00.386339+00:00","limit_dollars":null},
     "seven_day_opus":null,"pace":null,
     "limits":[
       {"kind":"weekly_all","group":"weekly","percent":40,"severity":"normal","resets_at":"2026-11-04T10:00:00.386339+00:00","scope":null,"is_active":true},
       {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-04T10:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}],
     "seven_day_breakdown":{"as_of":"2026-11-03T16:54:23.406942+00:00","window_started_at":"2026-10-28T10:00:00.386339+00:00","rows":[]}}
    """.utf8)

    @Test func noSessionLimitResponse() throws {
        let snapshot = try UsageAPI.parse(noSessionLimit, fetchedAt: fetchedAt)
        #expect(snapshot.session == nil)
        let weekly = try #require(snapshot.weekly)
        #expect(weekly.percent == 40)
        #expect(weekly.resetsAt == UsageAPI.parseDate("2026-11-04T10:00:00.386339+00:00"))
        #expect(weekly.startsAt == UsageAPI.parseDate("2026-10-28T10:00:00.386339+00:00"))
    }

    @Test func weeklyFallsBackToLimitsArray() throws {
        let data = Data("""
        {"five_hour":null,"seven_day":null,
         "limits":[{"kind":"weekly_all","group":"weekly","percent":62,"resets_at":"2026-11-04T10:00:00+00:00","is_active":true}]}
        """.utf8)
        let snapshot = try UsageAPI.parse(data, fetchedAt: fetchedAt)
        #expect(snapshot.weekly?.percent == 62)
        #expect(snapshot.weekly?.resetsAt == UsageAPI.parseDate("2026-11-04T10:00:00+00:00"))
        #expect(snapshot.weekly?.startsAt == nil)
        #expect(snapshot.session == nil)
    }

    @Test func classicResponseStillParses() throws {
        let data = Data("""
        {"five_hour":{"utilization":12.5,"resets_at":"2026-11-03T20:00:00+00:00"},
         "seven_day":{"utilization":40.0,"resets_at":"2026-11-04T10:00:00+00:00"}}
        """.utf8)
        let snapshot = try UsageAPI.parse(data, fetchedAt: fetchedAt)
        #expect(snapshot.session?.percent == 12.5)
        #expect(snapshot.weekly?.percent == 40)
    }

    @Test func inconsistentWindowStartIsIgnored() throws {
        let data = Data("""
        {"seven_day":{"utilization":40.0,"resets_at":"2026-11-04T10:00:00+00:00"},
         "seven_day_breakdown":{"window_started_at":"2026-11-01T10:00:00+00:00"}}
        """.utf8)
        #expect(try UsageAPI.parse(data, fetchedAt: fetchedAt).weekly?.startsAt == nil)
    }

    @Test func malformedLimitsDoNotFailTheResponse() throws {
        let data = Data("""
        {"seven_day":{"utilization":40.0,"resets_at":"2026-11-04T10:00:00+00:00"},"limits":"nope"}
        """.utf8)
        #expect(try UsageAPI.parse(data, fetchedAt: fetchedAt).weekly?.percent == 40)
    }
}

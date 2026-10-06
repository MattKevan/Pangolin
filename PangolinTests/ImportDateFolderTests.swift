import Foundation
import Testing

struct ImportDateFolderTests {
    @Test("The ISO8601 date style matches the old yyyy-MM-dd formatter in the local time zone")
    func dateStyleMatchesLegacyFormatter() {
        let legacy = DateFormatter()
        legacy.dateFormat = "yyyy-MM-dd"

        let dates = [
            Date(timeIntervalSince1970: 0),
            Date(timeIntervalSince1970: 1_767_225_599),
            Date(timeIntervalSince1970: 1_767_225_601),
            Date(timeIntervalSince1970: 1_751_327_999),
            Date()
        ]
        for date in dates {
            let modern = date.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day())
            #expect(modern == legacy.string(from: date))
        }
    }
}

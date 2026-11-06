import Foundation
import BoneRemoteSyncContent

// Unknown native fields (including local filesystem paths) are ignored by the safe projections.
enum KomgaCoding {
    static func decode<T: Decodable>(_ type: T.Type, _ response: ContentHTTPResponse) throws -> T {
        guard response.response.statusCode == 200 else { throw ContentServerError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw ContentServerError.invalidResponse }
            return date
        }
        do { return try decoder.decode(type, from: response.data) }
        catch { throw ContentServerError.invalidResponse }
    }

    static func encodeProgression(_ value: KomgaReadiumProgression) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        do { return try encoder.encode(value) }
        catch { throw ContentServerError.invalidReference }
    }
}

struct KomgaPageEnvelope<Item: Decodable & Sendable>: Decodable, Sendable {
    let content: [Item]
    let number: Int
    let size: Int
    let totalElements: Int
    let totalPages: Int
    let numberOfElements: Int
    let first: Bool
    let last: Bool
    let empty: Bool

    func page(requested: Int, pageSize: Int) throws -> ContentPage<Item> {
        guard number == requested, size == pageSize, totalElements >= 0, totalPages >= 0,
              numberOfElements == content.count, content.count <= size,
              first == (number == 0), empty == content.isEmpty else { throw ContentServerError.invalidResponse }
        let expectedPages = totalElements / size + (totalElements % size == 0 ? 0 : 1)
        let expectedCount = min(size, max(0, totalElements - number * size))
        guard totalPages == expectedPages, last == (number >= max(0, totalPages - 1)),
              content.count == expectedCount else { throw ContentServerError.invalidResponse }
        return .init(items: content, page: number, pageSize: size, total: totalElements, hasNextPage: !last)
    }
}

struct KomgaSearch: Encodable {
    struct Match: Encodable { let `operator` = "is"; let value: String }
    struct Condition: Encodable {
        var libraryId: Match?
        var seriesId: Match?
        var allOf: [Condition]?
    }
    let condition: Condition?
    let fullTextSearch: String?
    init(libraryID: String?, seriesID: String? = nil, search: String?) throws {
        var filters: [Condition] = []
        if let libraryID { filters.append(.init(libraryId: .init(value: try ContentValidation.id(libraryID)))) }
        if let seriesID { filters.append(.init(seriesId: .init(value: try ContentValidation.id(seriesID)))) }
        condition = filters.isEmpty ? nil : filters.count == 1 ? filters[0] : .init(allOf: filters)
        fullTextSearch = try search.map(ContentValidation.search)
    }
}

struct KomgaProgressPatch: Encodable { let page: Int?; let completed: Bool? }

enum KomgaValidation {
    static func id(_ value: String) throws {
        do { _ = try ContentValidation.id(value) }
        catch { throw ContentServerError.invalidResponse }
    }
    static func unique(_ values: [String]) throws {
        guard Set(values).count == values.count else { throw ContentServerError.invalidResponse }
        try values.forEach(id)
    }
    static func user(_ user: KomgaUser) throws {
        try id(user.id)
        try unique(user.sharedLibrariesIds)
        guard !user.email.isEmpty, user.ageRestriction.map({ $0.age >= 0 }) ?? true else {
            throw ContentServerError.invalidResponse
        }
    }
    static func series(_ series: KomgaSeries, id expected: String? = nil, libraryID: String? = nil) throws {
        try id(series.id); try id(series.libraryId)
        guard expected.map({ $0 == series.id }) ?? true,
              libraryID.map({ $0 == series.libraryId }) ?? true,
              [series.booksCount, series.booksReadCount, series.booksUnreadCount,
               series.booksInProgressCount, series.metadata.totalBookCount, series.metadata.ageRating]
                .compactMap({ $0 }).allSatisfy({ $0 >= 0 }) else { throw ContentServerError.invalidResponse }
        try calendarDate(series.booksMetadata?.releaseDate)
    }
    static func book(_ book: KomgaBook, id expected: String? = nil,
                     libraryID: String? = nil, seriesID: String? = nil) throws {
        try id(book.id); try id(book.libraryId); try id(book.seriesId)
        guard expected.map({ $0 == book.id }) ?? true,
              libraryID.map({ $0 == book.libraryId }) ?? true,
              seriesID.map({ $0 == book.seriesId }) ?? true,
              book.number >= 0, book.media.pagesCount >= 0, book.media.pagesCount <= Int32.max,
              book.sizeBytes.map({ $0 >= 0 }) ?? true,
              book.metadata.numberSort.map({ $0.isFinite }) ?? true,
              book.readProgress.map({ $0.page >= 0 && $0.page <= Int32.max }) ?? true else {
            throw ContentServerError.invalidResponse
        }
        try calendarDate(book.metadata.releaseDate)
    }
    private static func calendarDate(_ value: String?) throws {
        guard let value else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.utf8.count == 10, let date = formatter.date(from: value),
              formatter.string(from: date) == value else { throw ContentServerError.invalidResponse }
    }
    static func progression(_ value: KomgaReadiumProgression, writing: Bool) throws {
        let error: ContentServerError = writing ? .invalidReference : .invalidResponse
        func text(_ value: String?, limit: Int = 8192) throws {
            guard let value else { return }
            guard value.utf8.count <= limit,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw error }
        }
        guard value.modified.timeIntervalSince1970.isFinite,
              (-62_135_596_800...253_402_300_799).contains(value.modified.timeIntervalSince1970) else { throw error }
        try text(value.device.id); try text(value.device.name)
        let locator = value.locator
        try text(locator.href); try text(locator.type); try text(locator.title); try text(locator.koboSpan)
        // href is publication data, never followed by the transport.
        if writing && (locator.href.isEmpty || locator.type.isEmpty) { throw error }
        if let locations = locator.locations {
            for fraction in [locations.progression, locations.totalProgression].compactMap({ $0 }) {
                guard fraction.isFinite, (0...1).contains(fraction) else { throw error }
            }
            if let position = locations.position, !(1...Int(Int32.max)).contains(position) { throw error }
            guard (locations.fragments?.count ?? 0) <= 256 else { throw error }
            try locations.fragments?.forEach { try text($0) }
        }
        // Readium text may contain line breaks from the publication.
        for excerpt in [locator.text?.after, locator.text?.before, locator.text?.highlight].compactMap({ $0 }) {
            guard excerpt.utf8.count <= 65_536 else { throw error }
        }
    }
}

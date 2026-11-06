import Foundation
import BoneRemoteSyncCore
import BoneRemoteSyncContent

enum KavitaValidation {
    static func id(_ value: Int) throws {
        guard value > 0, value <= Int(Int32.max) else { throw ContentServerError.invalidReference }
    }
    static func responseID(_ value: Int) throws {
        guard value > 0, value <= Int(Int32.max) else { throw ContentServerError.invalidResponse }
    }
    static func nonnegative(_ value: Int) throws {
        guard value >= 0, value <= Int(Int32.max) else { throw ContentServerError.invalidResponse }
    }
    static func unique(_ ids: [Int]) throws {
        guard ids.count <= 10_000 else { throw ContentServerError.resourceLimit }
        guard Set(ids).count == ids.count else { throw ContentServerError.invalidResponse }
        for id in ids { try responseID(id) }
    }
    static func password(username: String, password: String) throws {
        guard !username.isEmpty, username.utf8.count <= 4096, !password.isEmpty, password.utf8.count <= 32768,
              !username.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RemoteSyncError.authenticationFailed(reason: "Invalid Kavita credential")
        }
    }
    static func series(_ value: KavitaSeries) throws {
        try responseID(value.id); try responseID(value.libraryID); try nonnegative(value.pages)
        if let pages = value.pagesRead { try nonnegative(pages) }
        if let reads = value.totalReads { try nonnegative(reads) }
        guard value.wordCount.map({ $0 >= 0 }) ?? true, value.userRating.map(\.isFinite) ?? true else {
            throw ContentServerError.invalidResponse
        }
    }
    static func volume(_ value: KavitaVolume) throws {
        try responseID(value.id); try responseID(value.seriesID); try nonnegative(value.pages)
        if let pages = value.pagesRead { try nonnegative(pages) }
        guard [value.minNumber, value.maxNumber].allSatisfy({ $0?.isFinite ?? true }) else {
            throw ContentServerError.invalidResponse
        }
        try unique(value.chapters.map(\.id))
        for item in value.chapters {
            try chapter(item)
            guard item.volumeID == value.id else { throw ContentServerError.invalidResponse }
        }
    }
    static func chapter(_ value: KavitaChapter) throws {
        try responseID(value.id); try responseID(value.volumeID); try nonnegative(value.pages)
        if let pages = value.pagesRead { try nonnegative(pages) }
        if let reads = value.totalReads { try nonnegative(reads) }
        guard [value.minNumber, value.maxNumber, value.sortOrder].allSatisfy({ $0?.isFinite ?? true }),
              value.wordCount.map({ $0 >= 0 }) ?? true else { throw ContentServerError.invalidResponse }
        try unique(value.files.map(\.id))
        for file in value.files {
            if let pages = file.pages { try nonnegative(pages) }
            guard file.bytes.map({ $0 >= 0 }) ?? true else { throw ContentServerError.invalidResponse }
        }
    }
    static func page(_ value: Int) throws {
        guard value >= 0, value <= Int(Int32.max) else { throw ContentServerError.invalidReference }
    }
    static func xpath(_ value: String?) throws {
        guard let value else { return }
        guard !value.isEmpty, value.utf8.count <= 16384,
              !value.lowercased().hasPrefix("epubcfi("),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ContentServerError.invalidReference
        }
    }
    struct Pagination: Decodable { let currentPage: Int; let itemsPerPage: Int; let totalItems: Int; let totalPages: Int }
    static func pagination(_ header: String?, page: Int, size: Int, count: Int) throws -> Pagination {
        guard let header, header.utf8.count <= 16384,
              let value = try? JSONDecoder().decode(Pagination.self, from: Data(header.utf8)),
              value.currentPage == page + 1, value.itemsPerPage == size,
              value.totalItems >= 0, value.totalItems <= Int(Int32.max), value.totalPages >= 0 else {
            throw ContentServerError.invalidResponse
        }
        let totalPages = value.totalItems / size + (value.totalItems % size == 0 ? 0 : 1)
        let expectedCount = min(size, max(0, value.totalItems - page * size))
        guard value.totalPages == totalPages, count == expectedCount else { throw ContentServerError.invalidResponse }
        return value
    }
    static func toc(_ items: [KavitaBookChapter], pages: Int) throws {
        var pending = items.map { ($0, 0) }, count = 0
        while let (item, depth) = pending.popLast() {
            count += 1
            guard count <= 10_000, depth <= 64 else { throw ContentServerError.resourceLimit }
            guard item.page >= 0, item.page < pages else { throw ContentServerError.invalidResponse }
            pending.append(contentsOf: (item.children ?? []).map { ($0, depth + 1) })
        }
    }
}

//
//  RepositoryFile.swift
//  Irisin
//

import AptRepository
import Foundation

/// The file types the app opens, as uniform type identifier strings and
/// extensions. iOS 12 port: UTType is iOS 14; the identifiers are the same
/// ones Info.plist declares.
enum IrisinFileType: String {
    /// `.irisinrepos`: repository addresses and nothing else. Both Share and
    /// Export Repository List write one, so a single repository and a whole
    /// list are the same file with a different number of entries. XML, so a
    /// reader who opens it in a text editor sees what they are about to add.
    case irisinRepositoryList = "wiki.qaq.irisin.repository-list"

    /// `.irisinrepo`: one repository with everything this app knows about it,
    /// its Release fields and its whole package catalogue. Binary, because a
    /// large repository's catalogue is the bulk of it.
    case irisinRepository = "wiki.qaq.irisin.repository"

    /// Debian's, not ours: the app is a viewer for it and nothing more.
    case debArchive = "org.debian.deb-archive"

    var identifier: String { rawValue }

    var fileExtension: String {
        switch self {
        case .irisinRepositoryList: "irisinrepos"
        case .irisinRepository: "irisinrepo"
        case .debArchive: "deb"
        }
    }

    /// What a file is, by its extension.
    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard let type = [Self.irisinRepositoryList, .irisinRepository, .debArchive].first(where: { $0.fileExtension == ext })
        else { return nil }
        self = type
    }
}

nonisolated enum RepositoryFileFailure: Error, Equatable {
    /// Written by a newer Irisin than this one.
    case unsupportedFormat
    /// Not one of our files at all.
    case unreadable
}

/// The version every file of ours carries. A file that says anything else is
/// refused rather than guessed at.
private nonisolated let currentRepositoryFileFormat = 1

/// What Share and Export Repository List write.
nonisolated struct RepositoryListFile: Codable {
    var format = currentRepositoryFileFormat
    var sources: [RepositorySource]

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        return try encoder.encode(self)
    }

    /// The repository addresses either of our files names, and only those:
    /// a `.irisinrepo` also carries Release fields and a package catalogue,
    /// and neither came from the server this run. Importing them would let a
    /// file hand the user a repository described in its own words; the
    /// refresh that follows an import says what the server says instead.
    ///
    /// A source the address parser would not accept is dropped, not refused:
    /// a list with one bad line still has the rest.
    /// The two fields of a `RepositoryFile` an import reads: decoding the
    /// whole file would build its catalogue, every package of it, to be
    /// thrown away.
    private struct Address: Decodable {
        var format: Int
        var source: RepositorySource
    }

    static func sources(in data: Data) throws -> [RepositorySource] {
        let decoder = PropertyListDecoder()
        if let list = try? decoder.decode(RepositoryListFile.self, from: data) {
            guard list.format == currentRepositoryFileFormat else { throw RepositoryFileFailure.unsupportedFormat }
            return list.sources.filter(\.isValid).uniqued()
        }
        if let one = try? decoder.decode(Address.self, from: data) {
            guard one.format == currentRepositoryFileFormat else { throw RepositoryFileFailure.unsupportedFormat }
            return [one.source].filter(\.isValid)
        }
        throw RepositoryFileFailure.unreadable
    }
}

/// One repository, whole: what Export All Repository Information writes.
///
/// The keychain is not in here. Neither is any networking header: a paid
/// repository's credentials are the device's, never a file's, and a copy of
/// this file is not a copy of an account.
nonisolated struct RepositoryFile: Codable {
    var format = currentRepositoryFileFormat
    var source: RepositorySource
    var name: String
    var release: [String: String]
    var releaseUpdatedAt: Date
    var packagesUpdatedAt: Date
    var packages: [Package]

    init(repository: Repository, packages: [Package]) {
        source = repository.source
        name = repository.nickName
        release = repository.metaRelease
        releaseUpdatedAt = repository.lastUpdateRelease
        packagesUpdatedAt = repository.lastUpdatePackage
        self.packages = packages
    }

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }
}

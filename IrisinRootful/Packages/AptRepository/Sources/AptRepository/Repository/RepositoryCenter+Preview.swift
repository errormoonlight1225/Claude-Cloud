//
//  RepositoryCenter+Preview.swift
//  AptRepository
//
//  Created by Lakr Aream on 2026/9/7.
//  Copyright © 2026 Lakr Aream. All rights reserved.
//

import Foundation
import LegacyCompat

/// What a repository looks like before it is registered: the label and
/// description from its Release file, and its icon.
public struct RepositoryPreview: Sendable {
    public let name: String
    public let description: String?
    public let avatar: Data?
}

public extension RepositoryCenter {
    /// Fetches the Release file and the icon of a source that is not
    /// registered. Nil when the address does not answer as a repository.
    nonisolated func preview(of source: RepositorySource) -> RepositoryPreview? {
        let repository = Repository(source: source)
        // no watchdog here to tell slow from dead, and the user is waiting
        // on this one address: the minute a slow server may need
        let (headers, verbose) = DispatchQueue.main.sync { (networkingHeaders, networkingVerboseLogging) }
        let networking = NetworkingConfiguration(
            headers: headers,
            timeout: 60,
            verboseLogging: verbose
        )
        return Self.fetchPreview(
            releaseUrl: repository.metaReleaseUrl,
            avatarUrls: repository.avatarUrls,
            networking: networking
        )
    }

    internal nonisolated static func fetchPreview(
        releaseUrl: URL,
        avatarUrls: [URL],
        networking: NetworkingConfiguration
    ) -> RepositoryPreview? {
        // iOS 12 port: a LegacyFuture where `async let` fetched the icon
        // beside the Release
        let avatar = LegacyFuture { downloadAvatar(from: avatarUrls, networking: networking) }
        guard let release = downloadData(fromUrl: releaseUrl, networking: networking),
              let meta = ReleaseFile.read(IndexText.decode(release))?.fields
        else {
            return nil
        }
        return RepositoryPreview(
            name: meta["label"] ?? meta["origin"] ?? releaseUrl.host ?? "repo",
            description: meta["description"] ?? meta["version"],
            avatar: avatar.value
        )
    }
}

import LegacyCompat
import AptRepository
import LegacyCrypto
import Foundation
import IrisinVendor

/// One download per package, into the run's own directory: nothing is
/// cached or resumed (Documentation/CommandLine.md). The file is checked
/// against the hash its repository published, as `Downloads.verify` does.
enum Fetch {
    static nonisolated func file(
        for package: Package,
        into directory: URL,
        context: Context,
        index: PackageIndex,
        output: Output
    ) throws -> URL {
        if let local = package.localFileURL {
            return local
        }
        let url = try link(for: package, index: index)
        output.line("Downloading \(package.identity) \(package.latestVersion ?? "")…")
        var request = URLRequest(url: url, timeoutInterval: 60)
        // as the app: HTTP/3 packets outgrow a VPN tunnel's MTU
        if #available(iOS 14.5, *) { request.assumesHTTP3Capable = false }
        let device = Vendor.device
        for (field, value) in ["X-Machine": device.machine, "X-Unique-ID": device.udid, "X-Firmware": device.firmware] {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let downloaded: URL
        do {
            let (file, response) = try URLSession.shared.compatDownload(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw CommandFailure.unavailable("\(package.identity) could not be downloaded: HTTP \(http.statusCode) from \(url.host ?? url.absoluteString).")
            }
            downloaded = file
        } catch let failure as CommandFailure {
            throw failure
        } catch {
            throw CommandFailure.unavailable("\(package.identity) could not be downloaded: \(error.localizedDescription)")
        }
        let destination = directory.appendingPathComponent(package.identity + ".deb")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: downloaded, to: destination)
        guard try verify(package, at: destination) else {
            throw CommandFailure.refused("\(package.identity)'s download does not match the hash its repository published. Try again.")
        }
        return destination
    }

    /// A paid package's link comes from its vendor, for the version and
    /// build the plan chose; every other package's from its repository.
    private static nonisolated func link(for package: Package, index: PackageIndex) throws -> URL {
        let commercial = package.latestMetadata?["tag"]?.contains("cydia::commercial") ?? false
        guard commercial,
              let repository = package.repoRef,
              let record = index.obtainRepositories().first(where: { $0.url == repository }),
              let endpoint = record.endpoint
        else {
            return package.obtainDownloadLink()
        }
        guard let credentials = VendorKeychain.credentials(for: repository) else {
            throw CommandFailure.refused("\(package.identity) is a paid package. Sign in to \(record.nickName) in Irisin first.")
        }
        let architecture = package.architectures.first { $0 != "all" } ?? AptEnvironment.current.deviceArchitecture
        let link: URL?
        do throws(VendorService.Failure) {
            link = try VendorService.downloadLink(
                for: package.identity,
                version: package.latestVersion,
                architecture: architecture,
                repository: repository,
                endpoint: endpoint,
                credentials: credentials,
                device: Vendor.device
            )
        } catch {
            throw Vendor.failure(error, at: endpoint)
        }
        guard let link else {
            throw CommandFailure.refused(
                "\(record.nickName) gave no download for \(package.identity). Check that it is bought: irisin-cli vendor status \(package.identity)."
            )
        }
        return link
    }

    /// The first hash the listing carries, sha256 before sha1 before md5;
    /// a listing with none is taken on trust, as the app takes it.
    static func verify(_ package: Package, at file: URL) throws -> Bool {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let metadata = package.latestMetadata ?? [:]
        // iOS 12 port: a generic where `any Sequence<UInt8>` needs iOS 16
        func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
            bytes.map { String(format: "%02x", $0) }.joined()
        }
        if let expected = metadata["sha256"] {
            return hex(SHA256.hash(data: data)) == expected.lowercased()
        }
        if let expected = metadata["sha1"] {
            return hex(Insecure.SHA1.hash(data: data)) == expected.lowercased()
        }
        if let expected = metadata["md5sum"] {
            return hex(Insecure.MD5.hash(data: data)) == expected.lowercased()
        }
        return true
    }
}

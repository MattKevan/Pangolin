import Foundation

struct ImportCandidate: Equatable, Sendable {
    let url: URL
    let fileName: String
    let fileSize: Int64

    init(url: URL, fileName: String? = nil, fileSize: Int64) {
        self.url = url
        self.fileName = fileName ?? url.lastPathComponent
        self.fileSize = fileSize
    }
}

struct ImportedVideoRecord: Equatable, Sendable {
    let sourcePath: String?
    let fileName: String?
    let fileSize: Int64
}

enum ImportDuplicatePolicy {
    static func uniqueCandidates(
        _ candidates: [ImportCandidate],
        existingRecords: [ImportedVideoRecord]
    ) -> [ImportCandidate] {
        var knownSourcePaths = Set(existingRecords.compactMap { record in
            record.sourcePath.map { path in
                canonicalSourcePath(URL(fileURLWithPath: path))
            }
        })
        var knownFileKeys: Set<FileKey> = Set(existingRecords.compactMap { record in
            guard let fileName = record.fileName else { return nil }
            return FileKey(fileName: fileName, fileSize: record.fileSize)
        })

        return candidates.filter { candidate in
            let sourcePath = canonicalSourcePath(candidate.url)
            let fileKey = FileKey(fileName: candidate.fileName, fileSize: candidate.fileSize)
            guard !knownSourcePaths.contains(sourcePath), !knownFileKeys.contains(fileKey) else {
                return false
            }

            knownSourcePaths.insert(sourcePath)
            knownFileKeys.insert(fileKey)
            return true
        }
    }

    static func canonicalSourcePath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private struct FileKey: Hashable {
        let fileName: String
        let fileSize: Int64
    }
}

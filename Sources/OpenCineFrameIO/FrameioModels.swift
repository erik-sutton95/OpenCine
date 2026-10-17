import Foundation

// Frame.io v4 response shapes below follow the public docs and the v4 `data`-envelope convention.
// Exact field names are [verify-with-credentials]: confirm against the first live responses and
// adjust CodingKeys if needed. Kept intentionally minimal: only what the connect + upload flow uses.

/// A Frame.io account: the top-level ownership resource that prefixes most v4 endpoints.
public struct FrameioAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

/// A Frame.io workspace (legacy "team"): projects are listed per workspace.
public struct FrameioWorkspace: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
}

/// A Frame.io project. Clips upload into the project's root folder.
public struct FrameioProject: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let rootFolderID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case rootFolderID = "root_folder_id"
    }
}

/// Create Project request body (`POST …/workspaces/{id}/projects`).
public struct FrameioCreateProjectRequest: Codable, Equatable, Sendable {
    public let data: Body

    public struct Body: Codable, Equatable, Sendable {
        public let name: String

        public init(name: String) { self.name = name }
    }

    public init(name: String) { self.data = Body(name: name) }
}

/// The authenticated user (`GET /v4/me`): used to confirm a connection succeeded.
public struct FrameioUser: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String?
    public let email: String?
}

/// v4 `data`-enveloped responses.
public struct FrameioList<Element: Codable & Sendable>: Codable, Sendable {
    public let data: [Element]
}
public struct FrameioOne<Element: Codable & Sendable>: Codable, Sendable {
    public let data: Element
}

/// Create File (local upload) request body: registers a placeholder file to receive an upload.
public struct FrameioCreateFileRequest: Codable, Equatable, Sendable {
    public let data: Body

    public struct Body: Codable, Equatable, Sendable {
        public let name: String
        public let fileSize: Int

        enum CodingKeys: String, CodingKey {
            case name
            case fileSize = "file_size"
        }
    }

    public init(name: String, fileSize: Int) {
        self.data = Body(name: name, fileSize: fileSize)
    }
}

/// One part of a Create File response: a pre-signed S3 URL and the byte size for that chunk.
public struct FrameioUploadPart: Codable, Equatable, Sendable {
    public let size: Int
    public let url: String

    public var uploadURL: URL? { URL(string: url) }
}

/// Create File (local upload) response: the placeholder file id plus one or more pre-signed S3
/// upload URLs (more than one when the file is large enough to be split into parts).
public struct FrameioCreateFileResponse: Codable, Equatable, Sendable {
    public let data: Body

    public struct Body: Codable, Equatable, Sendable {
        public let id: String
        public let uploadParts: [FrameioUploadPart]
        public let mediaType: String?

        enum CodingKeys: String, CodingKey {
            case id
            case uploadParts = "upload_urls"
            case mediaType = "media_type"
        }
    }

    public var fileID: String { data.id }
    /// MIME type inferred by Frame.io for the created file (use as S3 `Content-Type`).
    public var mediaType: String? { data.mediaType }
    /// Pre-signed S3 URLs to `PUT` the bytes to (in order).
    public var uploadURLs: [URL] { data.uploadParts.compactMap(\.uploadURL) }
    /// Ordered upload parts: each `size` bytes go to the matching pre-signed URL.
    public var uploadParts: [FrameioUploadPart] { data.uploadParts }
}

/// `GET /files/{file_id}/status`: whether Frame.io has received every uploaded part.
public struct FrameioFileUploadStatus: Codable, Equatable, Sendable {
    public let data: Body

    public struct Body: Codable, Equatable, Sendable {
        public let id: String
        public let uploadComplete: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case uploadComplete = "upload_complete"
        }
    }

    public var fileID: String { data.id }
    public var uploadComplete: Bool { data.uploadComplete }
}

/// Guesses a MIME type from a filename extension when Frame.io omits `media_type`.
public enum FrameioMediaType {
    public static func forFilename(_ filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        default: "application/octet-stream"
        }
    }
}

/// Thrown when a Frame.io API response cannot be decoded; includes a response-body snippet.
public struct FrameioDecodingError: LocalizedError, Sendable {
    public let responseBody: String
    public let underlying: Error

    public init(responseBody: String, underlying: Error) {
        self.responseBody = responseBody
        self.underlying = underlying
    }

    public var errorDescription: String? {
        "Frame.io response couldn't be parsed: \(underlying.localizedDescription). Body: \(responseBody)"
    }
}

/// Decodes Frame.io JSON and surfaces the response body when decoding fails.
public enum FrameioJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            throw FrameioDecodingError(responseBody: body, underlying: error)
        }
    }
}

/// The projects of one workspace, as the delivery popup lists them.
public struct FrameioProjectListing: Equatable, Sendable {
    public var accountID: String
    public var workspaceID: String
    public var workspaceName: String
    public var projects: [FrameioProject]
    public init(accountID: String, workspaceID: String, workspaceName: String, projects: [FrameioProject]) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.projects = projects
    }
}

/// The upload target: one project's root folder. Each app persists it in its own namespace.
public struct FrameioDestination: Codable, Equatable, Sendable {
    public var accountID: String
    public var workspaceID: String?
    public var projectID: String
    public var projectName: String
    public var folderID: String
    public init(
        accountID: String, workspaceID: String?, projectID: String, projectName: String,
        folderID: String
    ) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.projectName = projectName
        self.folderID = folderID
    }
    /// The project's root folder in a listing, or nil when the project has none.
    public init?(project: FrameioProject, in listing: FrameioProjectListing) {
        guard let folder = project.rootFolderID else { return nil }
        self.init(
            accountID: listing.accountID, workspaceID: listing.workspaceID, projectID: project.id,
            projectName: project.name, folderID: folder)
    }
}

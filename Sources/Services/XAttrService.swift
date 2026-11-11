import Foundation
import Darwin

// MARK: - Extended-attribute service
//
// Native Swift wrapper over macOS xattr(2): listxattr, getxattr, setxattr,
// removexattr. Works on any file or folder path, including paths outside the
// app sandbox (Full Disk Access is required for system files, but regular
// user files work automatically). Values are arbitrary Data; convenience
// helpers read/write UTF-8 strings and Finder comments.

enum XAttrError: Error, LocalizedError {
    case invalidPath
    case attributeNotFound(name: String)
    case posixError(errno: Int32, operation: String)

    var errorDescription: String? {
        switch self {
        case .invalidPath:
            return "Invalid or empty file path."
        case .attributeNotFound(let name):
            return "Extended attribute '\(name)' does not exist on this file."
        case .posixError(let code, let operation):
            return String(format: "xattr operation '%@' failed: %s (%d)",
                          operation, strerror(code) ?? "unknown error", code)
        }
    }
}

/// Namespace constants used by SwiftMaestro and Finder.
extension String {
    /// Finder's Spotlight-backed comment attribute. Stored as a binary plist
    /// containing a single NSString.
    static let finderCommentKey = "com.apple.metadata:kMDItemFinderComment"

    /// MaestroDAM metadata namespace. Sub-keys are written as separate xattrs
    /// (e.g. `com.woodseedigi.SwiftMaestro.DAM.description`) so Finder and
    /// third-party tools can read them without parsing a private plist.
    static let maestroDAMNamespace = "com.woodseedigi.SwiftMaestro.DAM"
}

enum XAttrService {

    // MARK: - Low-level operations

    /// Returns all extended-attribute names on the file or directory at `url`.
    static func list(at url: URL) throws -> [String] {
        let path = url.path
        guard !path.isEmpty else { throw XAttrError.invalidPath }

        let size = listxattr(path, nil, 0, 0)
        if size < 0 {
            throw posixError(operation: "listxattr")
        }
        if size == 0 { return [] }

        var buffer = [CChar](repeating: 0, count: size)
        let rc = listxattr(path, &buffer, size, 0)
        if rc < 0 {
            throw posixError(operation: "listxattr")
        }

        var names: [String] = []
        var i = 0
        while i < rc {
            let end = (i..<rc).first { buffer[$0] == 0 } ?? rc
            let length = end - i
            if length > 0,
               let name = String(bytes: buffer[i..<end].map { UInt8(bitPattern: $0) },
                                encoding: .utf8),
               !name.isEmpty {
                names.append(name)
            }
            i = end + 1
        }
        return names
    }

    /// Reads the raw bytes of extended attribute `name`.
    static func read(at url: URL, name: String) throws -> Data {
        let path = url.path
        guard !path.isEmpty else { throw XAttrError.invalidPath }
        guard !name.isEmpty else { throw XAttrError.invalidPath }

        let size = getxattr(path, name, nil, 0, 0, 0)
        if size < 0 {
            if errno == ENOATTR {
                throw XAttrError.attributeNotFound(name: name)
            }
            throw posixError(operation: "getxattr")
        }
        if size == 0 { return Data() }

        var buffer = [UInt8](repeating: 0, count: size)
        let rc = getxattr(path, name, &buffer, size, 0, 0)
        if rc < 0 {
            if errno == ENOATTR {
                throw XAttrError.attributeNotFound(name: name)
            }
            throw posixError(operation: "getxattr")
        }
        return Data(buffer)
    }

    /// Writes raw bytes to extended attribute `name`, replacing any existing
    /// value of the same name.
    static func write(at url: URL, name: String, data: Data) throws {
        let path = url.path
        guard !path.isEmpty else { throw XAttrError.invalidPath }
        guard !name.isEmpty else { throw XAttrError.invalidPath }

        let bytes = [UInt8](data)
        let rc = setxattr(path, name, bytes, data.count, 0, 0)
        if rc != 0 {
            throw posixError(operation: "setxattr")
        }
    }

    /// Removes extended attribute `name`. Throws `.attributeNotFound` if it
    /// does not already exist.
    static func remove(at url: URL, name: String) throws {
        let path = url.path
        guard !path.isEmpty else { throw XAttrError.invalidPath }
        guard !name.isEmpty else { throw XAttrError.invalidPath }

        let rc = removexattr(path, name, 0)
        if rc != 0 {
            if errno == ENOATTR {
                throw XAttrError.attributeNotFound(name: name)
            }
            throw posixError(operation: "removexattr")
        }
    }

    // MARK: - String conveniences

    /// Reads an xattr as a UTF-8 string. Throws if decoding fails.
    static func string(at url: URL, name: String) throws -> String {
        let data = try read(at: url, name: name)
        guard let text = String(data: data, encoding: .utf8) else {
            throw XAttrError.posixError(errno: EILSEQ, operation: "utf8 decode")
        }
        return text
    }

    /// Writes a UTF-8 string to an xattr.
    static func write(at url: URL, name: String, string: String) throws {
        guard let data = string.data(using: .utf8) else {
            throw XAttrError.posixError(errno: EILSEQ, operation: "utf8 encode")
        }
        try write(at: url, name: name, data: data)
    }

    // MARK: - Finder comment

    /// Reads Finder's Get Info comment, if any.
    static func finderComment(at url: URL) throws -> String? {
        guard let data = try? read(at: url, name: .finderCommentKey) else { return nil }
        let plist = try PropertyListSerialization.propertyList(
            from: data, options: PropertyListSerialization.ReadOptions(), format: nil)
        return plist as? String
    }

    /// Sets Finder's Get Info comment (visible in Finder's Inspector and on
    /// icon hover). Stored as a binary plist string, matching Finder's format.
    static func setFinderComment(at url: URL, comment: String) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: comment, format: .binary,
            options: PropertyListSerialization.WriteOptions())
        try write(at: url, name: .finderCommentKey, data: data)
    }

    // MARK: - MaestroDAM helpers

    static func damKey(_ suffix: String) -> String {
        "\(String.maestroDAMNamespace).\(suffix)"
    }

    static func maestroDAMDescription(at url: URL) throws -> String? {
        try string(at: url, name: damKey("description"))
    }

    static func setMaestroDAMDescription(at url: URL, description: String) throws {
        try write(at: url, name: damKey("description"), string: description)
    }

    static func maestroDAMKeywords(at url: URL) throws -> [String] {
        guard let text = try? string(at: url, name: damKey("keywords")) else { return [] }
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func setMaestroDAMKeywords(at url: URL, keywords: [String]) throws {
        let text = keywords.joined(separator: ", ")
        try write(at: url, name: damKey("keywords"), string: text)
    }

    // MARK: - Private helpers

    private static func posixError(operation: String) -> XAttrError {
        XAttrError.posixError(errno: errno, operation: operation)
    }
}

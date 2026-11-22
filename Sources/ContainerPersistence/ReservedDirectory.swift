//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Foundation
import SystemPackage

/// The state directory of an entity, reserved by the create call that made it.
///
/// Entity names are compared exactly in memory, but the file system that holds the state
/// directories can compare them differently: on a case-insensitive APFS volume (the macOS
/// default) `Foo` and `foo` name one directory, and Unicode normalisation can fold other
/// spellings together. A create that writes into `<root>/<name>` without a reservation then
/// writes into, formats or later deletes the state of another entity.
///
/// `reserve` uses `mkdir(2)`, which fails when the file system already has an entry under an
/// equal name, so the file system decides what "the same name" is. A create writes only inside
/// a directory that it reserved, and a failed create removes only that directory.
///
/// A reservation is marked: `reserve` writes the file `.reserved`, holding a token of its own,
/// before anything else, and `publish` removes it when the create has written its entity. A
/// directory that holds nothing, or only a marker in that format, was left by a create that
/// stopped before it wrote anything (a crash, or an older version that made the directory before
/// it checked its options). Such a directory is abandoned and may be reclaimed. A directory with
/// anything else in it, including a `.reserved` that this code did not write, is never removed
/// here. A rollback and a publish act only on a marker with their own token, so a create never
/// removes a directory that another reservation took over.
public struct ReservedDirectory: Sendable {
    public let path: FilePath
    /// The content of this reservation's marker.
    public let token: String

    public static let markerName = ".reserved"
    private static let tokenPrefix = "container-reservation v1 "

    /// The file system already has an entry under a name equal to the last component of `path`.
    public struct Exists: Error, CustomStringConvertible {
        public let path: FilePath
        public var description: String { "\(path.string) already exists" }
    }

    private init(path: FilePath, token: String) {
        self.path = path
        self.token = token
    }

    /// The token of a marker that this code wrote, or nil for anything else at that path.
    private static func markerToken(in directory: FilePath) -> String? {
        let marker = directory.appending(markerName)
        var info = stat()
        guard lstat(marker.string, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 128,
            let data = FileManager.default.contents(atPath: marker.string),
            let text = String(data: data, encoding: .utf8), text.hasPrefix(tokenPrefix),
            UUID(uuidString: String(text.dropFirst(tokenPrefix.count))) != nil
        else {
            return nil
        }
        return text
    }

    /// Creates the directory `path`. Its parent must exist.
    ///
    /// - Throws: `Exists` when an entry with an equal name exists, or a `POSIXError` for any
    ///   other failure. Nothing is created when it throws.
    public static func reserve(_ path: FilePath) throws -> ReservedDirectory {
        guard mkdir(path.string, 0o755) == 0 else {
            let code = errno
            if code == EEXIST {
                throw Exists(path: path)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let directory = ReservedDirectory(path: path, token: tokenPrefix + UUID().uuidString)
        do {
            let marker = try directory.createFile(markerName)
            try Data(directory.token.utf8).write(to: URL(fileURLWithPath: marker.string))
        } catch {
            _ = unlink(path.appending(markerName).string)
            rmdir(path.string)
            throw error
        }
        return directory
    }

    /// The directory no longer holds this reservation's marker: another reservation took it over.
    public struct NotOurs: Error, CustomStringConvertible {
        public let path: FilePath
        public var description: String { "\(path.string) is no longer this create's reservation; it was left as it is" }
    }

    /// Marks the create as complete: the directory now holds an entity. Removes the marker only
    /// when it is this reservation's own.
    public func publish() throws {
        guard Self.markerToken(in: path) == token else {
            throw NotOurs(path: path)
        }
        guard unlink(path.appending(Self.markerName).string) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Whether `path` is a directory (not a link) that holds nothing, or only a marker that this
    /// code wrote.
    public static func isAbandoned(_ path: FilePath) -> Bool {
        var info = stat()
        guard lstat(path.string, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            let entries = try? FileManager.default.contentsOfDirectory(atPath: path.string)
        else {
            return false
        }
        if entries.isEmpty {
            return true
        }
        return entries == [markerName] && markerToken(in: path) != nil
    }

    /// Removes `path` when it is abandoned; returns whether it did.
    @discardableResult
    public static func reclaimIfAbandoned(_ path: FilePath) -> Bool {
        guard isAbandoned(path) else {
            return false
        }
        _ = unlink(path.appending(markerName).string)
        return rmdir(path.string) == 0
    }

    /// Creates the empty file `name` inside the reserved directory, failing if it exists.
    @discardableResult
    public func createFile(_ name: String) throws -> FilePath {
        let file = path.appending(name)
        let fd = open(file.string, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(fd)
        return file
    }

    /// Removes the reserved directory and everything in it, when it still holds this
    /// reservation's marker. Use only to undo the create that reserved it.
    public func release() throws {
        guard Self.markerToken(in: path) == token else {
            throw NotOurs(path: path)
        }
        try FileManager.default.removeItem(atPath: path.string)
    }

    /// Whether `a` and `b` lead to the same file system entry (same device and inode), following
    /// symbolic links. False when either cannot be read.
    public static func sameEntry(_ a: FilePath, _ b: FilePath) -> Bool {
        var sa = stat()
        var sb = stat()
        guard stat(a.string, &sa) == 0, stat(b.string, &sb) == 0 else {
            return false
        }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }
}

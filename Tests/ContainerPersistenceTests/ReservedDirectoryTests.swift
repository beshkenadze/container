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

import ContainerPersistence
import ContainerTestSupport
import Foundation
import SystemPackage
import Testing

struct ReservedDirectoryTests {
    private func exists(_ path: FilePath) -> Bool { FileManager.default.fileExists(atPath: path.string) }

    @Test("a reservation is marked until it is published")
    func markerLifecycle() async throws {
        try await TemporaryStorage.withTempDir { root in
            let directory = try ReservedDirectory.reserve(root.appending("v"))
            #expect(exists(root.appending("v").appending(ReservedDirectory.markerName)))
            #expect(ReservedDirectory.isAbandoned(directory.path))
            try directory.createFile("data")
            try directory.publish()
            #expect(!exists(root.appending("v").appending(ReservedDirectory.markerName)))
            #expect(!ReservedDirectory.isAbandoned(directory.path))
            #expect(throws: ReservedDirectory.Exists.self) { _ = try ReservedDirectory.reserve(root.appending("v")) }
        }
    }

    @Test("only an empty or marker-only directory is reclaimed; anything else stays as it is")
    func reclaim() async throws {
        try await TemporaryStorage.withTempDir { root in
            let fm = FileManager.default
            try fm.createDirectory(atPath: root.appending("empty").string, withIntermediateDirectories: false)
            try fm.createDirectory(atPath: root.appending("marked").string, withIntermediateDirectories: false)
            fm.createFile(atPath: root.appending("marked").appending(ReservedDirectory.markerName).string, contents: nil)
            try fm.createDirectory(atPath: root.appending("held").string, withIntermediateDirectories: false)
            fm.createFile(atPath: root.appending("held").appending(ReservedDirectory.markerName).string, contents: nil)
            fm.createFile(atPath: root.appending("held").appending("volume.img").string, contents: Data("x".utf8))
            try fm.createSymbolicLink(atPath: root.appending("link").string, withDestinationPath: root.appending("empty").string)

            #expect(!ReservedDirectory.reclaimIfAbandoned(root.appending("link")))
            #expect(exists(root.appending("link")))
            #expect(ReservedDirectory.reclaimIfAbandoned(root.appending("empty")))
            #expect(ReservedDirectory.reclaimIfAbandoned(root.appending("marked")))
            #expect(!ReservedDirectory.reclaimIfAbandoned(root.appending("held")))
            #expect(!exists(root.appending("empty")) && !exists(root.appending("marked")))
            #expect(exists(root.appending("held").appending("volume.img")))
        }
    }
}

extension ReservedDirectoryTests {
    @Test("a rollback and a publish leave a directory that another reservation took over")
    func rollbackOnlyOwnReservation() async throws {
        try await TemporaryStorage.withTempDir { root in
            let directory = try ReservedDirectory.reserve(root.appending("v"))
            // Another reservation of the same path (another server on the root, after a reclaim).
            let other = "container-reservation v1 \(UUID().uuidString)"
            try Data(other.utf8).write(to: URL(fileURLWithPath: root.appending("v").appending(ReservedDirectory.markerName).string))
            try Data("its image".utf8).write(to: URL(fileURLWithPath: root.appending("v").appending("volume.img").string))

            #expect(throws: ReservedDirectory.NotOurs.self) { try directory.release() }
            #expect(throws: ReservedDirectory.NotOurs.self) { try directory.publish() }
            #expect(FileManager.default.fileExists(atPath: root.appending("v").appending("volume.img").string))
            #expect(FileManager.default.fileExists(atPath: root.appending("v").appending(ReservedDirectory.markerName).string))
        }
    }
}

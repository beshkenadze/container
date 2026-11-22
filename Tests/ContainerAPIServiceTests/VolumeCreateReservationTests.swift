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

import ContainerAPIService
import ContainerPersistence
import ContainerPlugin
import ContainerResource
import ContainerTestSupport
import Foundation
import Logging
import SystemPackage
import Testing

/// A volume create never writes into a volume directory that it did not create.
struct VolumeCreateReservationTests {
    private let log = Logger(label: "test")
    private let small = ["size": "4M"]

    private func makeVolumesService(appRoot: FilePath) async throws -> VolumesService {
        let appURL = URL(fileURLWithPath: appRoot.string)
        let pluginLoader = try PluginLoader(
            appRoot: appURL,
            installRoot: appURL,
            logRoot: nil,
            pluginDirectories: [],
            pluginFactories: []
        )
        let containers = try ContainersService(
            appRoot: appURL,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
        return try await VolumesService(
            resourceRoot: appRoot.appending("volumes"),
            containersService: containers,
            log: log
        )
    }

    private struct FileState: Equatable {
        let inode: UInt64
        let bytes: Data
    }

    private func state(of path: FilePath) throws -> FileState {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.string)
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return FileState(inode: inode, bytes: try Data(contentsOf: URL(fileURLWithPath: path.string)))
    }

    /// Whether `root` compares names without case: a file made as `Probe` is found as `probe`.
    private func isCaseInsensitive(_ root: FilePath) throws -> Bool {
        let probe = root.appending("CaseProbe")
        try Data().write(to: URL(fileURLWithPath: probe.string))
        defer { try? FileManager.default.removeItem(atPath: probe.string) }
        return FileManager.default.fileExists(atPath: root.appending("caseprobe").string)
    }

    @Test("a create does not format an image that is already in the volume directory")
    func createRefusesALeftOverImage() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)
            let directory = appRoot.appending("volumes/left")
            try FileManager.default.createDirectory(atPath: directory.string, withIntermediateDirectories: true)
            let image = directory.appending("volume.img")
            try Data("user data that must stay".utf8).write(to: URL(fileURLWithPath: image.string))
            let before = try state(of: image)

            await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "left", driverOpts: small)
            }

            #expect(try state(of: image) == before)
            #expect(try await service.list().isEmpty)
        }
    }

    @Test("a name that the file system folds onto an existing volume is refused and the volume stays whole")
    func caseVariantDoesNotTouchTheExistingVolume() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)
            let first = try await service.create(name: "CaseVol", driverOpts: small)
            let image = FilePath(first.source)
            let entity = appRoot.appending("volumes/CaseVol/entity.json")
            let imageBefore = try state(of: image)
            let entityBefore = try state(of: entity)

            if try isCaseInsensitive(appRoot) {
                let error = await #expect(throws: VolumeError.self) {
                    _ = try await service.create(name: "casevol", driverOpts: small)
                }
                #expect(try state(of: image) == imageBefore)
                #expect(try state(of: entity) == entityBefore)
                #expect(try await service.list().map(\.name) == ["CaseVol"])
                if case .volumeAlreadyExists(let existing) = error {
                    #expect(existing == "CaseVol")
                } else {
                    Issue.record("expected volumeAlreadyExists(CaseVol), got \(String(describing: error))")
                }
            } else {
                _ = try await service.create(name: "casevol", driverOpts: small)
                #expect(Set(try await service.list().map(\.name)) == ["CaseVol", "casevol"])
                #expect(try state(of: image) == imageBefore)
                #expect(try state(of: entity) == entityBefore)
            }
            #expect(try await service.inspect("CaseVol").source == first.source)
        }
    }

    @Test("a create that fails on its options leaves nothing behind, and the retry succeeds")
    func failedCreateLeavesNothing() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)

            await #expect(throws: (any Error).self) {
                _ = try await service.create(name: "retry", driverOpts: ["size": "4M", "journal": "bogus"])
            }
            #expect(!FileManager.default.fileExists(atPath: appRoot.appending("volumes/retry").string))

            let volume = try await service.create(name: "retry", driverOpts: small)
            #expect(FileManager.default.fileExists(atPath: volume.source))
        }
    }

    @Test("the exact name of an existing volume is still refused as already existing")
    func exactNameIsRefused() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try await makeVolumesService(appRoot: appRoot)
            let first = try await service.create(name: "same", driverOpts: small)
            let before = try state(of: FilePath(first.source))

            let error = await #expect(throws: VolumeError.self) {
                _ = try await service.create(name: "same", driverOpts: small)
            }
            #expect(try state(of: FilePath(first.source)) == before)
            if case .volumeAlreadyExists("same") = error {
            } else {
                Issue.record("expected volumeAlreadyExists(same), got \(String(describing: error))")
            }
        }
    }
}

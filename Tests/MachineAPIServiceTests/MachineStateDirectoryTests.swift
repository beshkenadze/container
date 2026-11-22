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
import ContainerResource
import ContainerTestSupport
import ContainerizationError
import ContainerizationOCI
import Foundation
import Logging
import MachineAPIClient
import MachineAPIService
import SystemPackage
import Testing

/// A machine's state directory belongs to one machine: a create never writes into the bundle
/// of another machine whose name the file system folds onto the same entry, and a bundle whose
/// configuration names another machine is kept as it is.
struct MachineStateDirectoryTests {
    private let log = Logger(label: "test")

    /// The layout of `config.json` in a machine bundle.
    private struct PersistedConfig: Encodable {
        let configuration: MachineConfiguration
        let createdDate: Date?
    }

    private func configuration(id: String) throws -> MachineConfiguration {
        let image = ImageDescription(
            reference: "folded-name-test.invalid/none:none",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        return try MachineConfiguration(
            id: id,
            image: image,
            platform: Platform(arch: "arm64", os: "linux"),
            userSetup: UserSetup(username: "test", uid: 501, gid: 20)
        )
    }

    private func bootConfig() throws -> MachineConfig {
        try MachineConfig(cpus: nil, memory: nil, homeMount: nil, virtualization: nil, kernelPath: nil)
    }

    /// The resource root that the service copies the machine init from.
    private func resourceRoot(_ appRoot: FilePath) throws -> FilePath {
        let root = appRoot.appending("resources")
        try FileManager.default.createDirectory(atPath: root.string, withIntermediateDirectories: true)
        try Data("init".utf8).write(to: URL(fileURLWithPath: root.appending("init").string))
        return root
    }

    /// Writes a machine bundle into `machines/<directory>` whose configuration names `id`.
    private func writeMachine(appRoot: FilePath, directory: String, id: String) throws -> URL {
        let path = appRoot.appending("machines").appending(directory)
        try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
        let bundle = MachineBundle(path: path)
        try bundle.write(filename: "config.json", value: PersistedConfig(configuration: configuration(id: id), createdDate: nil))
        try bundle.write(filename: MachineBundle.bootConfigFile, value: bootConfig())
        let url = URL(fileURLWithPath: path.string)
        try Data("data the machine wrote".utf8).write(to: url.appendingPathComponent("rootfs.ext4"))
        return url
    }

    /// The files at the top of `directory`, without the init binary that every load refreshes.
    private func contents(of directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            var isDirectory: ObjCBool = false
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            result[name] = try Data(contentsOf: url)
        }
        return result
    }

    private static func tempDirIsCaseInsensitive() -> Bool {
        let base = FileManager.default.temporaryDirectory
        let probe = base.appendingPathComponent("CaseProbe-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: nil) else {
            return false
        }
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: base.appendingPathComponent(probe.lastPathComponent.lowercased()).path)
    }

    @Test(
        "a create whose name the file system folds onto an existing machine is refused before anything is written",
        .enabled(if: tempDirIsCaseInsensitive(), "needs a case-insensitive temporary directory")
    )
    func createRefusesAFoldedName() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let resources = try resourceRoot(appRoot)
            let directory = try writeMachine(appRoot: appRoot, directory: "mfold", id: "mfold")
            let service = try MachinesService(appRoot: appRoot, resourceRoot: resources, log: log)
            let before = try contents(of: directory)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.create(configuration: configuration(id: "MFOLD"), bootConfig: bootConfig())
            }
            #expect(error?.code == .exists)
            #expect(error?.message.contains("'mfold'") == true)
            #expect(try contents(of: directory) == before)
        }
    }

    @Test(
        "a healthy machine whose bundle name differs only in case loads and deletes",
        .enabled(if: tempDirIsCaseInsensitive(), "needs a case-insensitive temporary directory")
    )
    func caseRenamedBundleIsHealthy() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let resources = try resourceRoot(appRoot)
            let directory = try writeMachine(appRoot: appRoot, directory: "mdir", id: "MDIR")
            let service = try MachinesService(appRoot: appRoot, resourceRoot: resources, log: log)

            #expect(try await service.list().map(\.id) == ["MDIR"])
            try await service.delete(id: "MDIR")
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("a bundle that its machine's ID does not lead to is kept, and its delete is refused")
    func unreachableBundleIsKept() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let resources = try resourceRoot(appRoot)
            let directory = try writeMachine(appRoot: appRoot, directory: "mx", id: "my")
            let service = try MachinesService(appRoot: appRoot, resourceRoot: resources, log: log)
            let before = try contents(of: directory)

            #expect(try await service.list().map(\.id) == ["my"])
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: "my")
            }
            #expect(error?.code == .invalidState)
            #expect(try contents(of: directory) == before)
        }
    }

    @Test("a machine whose bundle holds its own configuration still deletes")
    func ordinaryMachineDeletes() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let resources = try resourceRoot(appRoot)
            let directory = try writeMachine(appRoot: appRoot, directory: "mok", id: "mok")
            let service = try MachinesService(appRoot: appRoot, resourceRoot: resources, log: log)

            try await service.delete(id: "mok")
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("the load removes an abandoned machine bundle directory")
    func loadReclaimsAnAbandonedBundle() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let resources = try resourceRoot(appRoot)
            let left = appRoot.appending("machines").appending("mleft")
            try FileManager.default.createDirectory(atPath: left.string, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: left.appending(ReservedDirectory.markerName).string, contents: nil)

            _ = try MachinesService(appRoot: appRoot, resourceRoot: resources, log: log)

            #expect(!FileManager.default.fileExists(atPath: left.string))
        }
    }
}

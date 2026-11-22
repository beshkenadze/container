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
import ContainerResource
import ContainerRuntimeClient
import ContainerTestSupport
import Containerization
import ContainerizationError
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerPlugin

/// A container's state directory belongs to one container: a create never writes into the
/// directory of another container whose name the file system folds onto the same entry, and a
/// directory that two names already share is kept as it is.
struct ContainerStateDirectoryTests {
    private let log = Logger(label: "test")

    private struct RuntimePluginFactory: PluginFactory {
        func create(installURL: URL) throws -> Plugin? {
            guard installURL.lastPathComponent == "container-runtime-linux" else {
                return nil
            }
            let services = PluginConfig.ServicesConfig(
                loadAtBoot: false,
                runAtLoad: false,
                services: [PluginConfig.Service(type: .runtime, description: nil)],
                defaultArguments: []
            )
            return Plugin(
                binaryURL: installURL.appendingPathComponent("container-runtime-linux"),
                config: PluginConfig(abstract: "runtime", author: nil, servicesConfig: services)
            )
        }

        func create(parentURL: URL, name: String) throws -> Plugin? {
            try create(installURL: parentURL.appendingPathComponent(name))
        }
    }

    private func makeService(appRoot: FilePath) throws -> ContainersService {
        let appURL = URL(fileURLWithPath: appRoot.string)
        let plugins = appURL.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(
            at: plugins.appendingPathComponent("container-runtime-linux"), withIntermediateDirectories: true)
        let pluginLoader = try PluginLoader(
            appRoot: appURL,
            installRoot: appURL,
            logRoot: nil,
            pluginDirectories: [plugins],
            pluginFactories: [RuntimePluginFactory()]
        )
        return try ContainersService(
            appRoot: appURL,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
    }

    private func configuration(id: String) -> ContainerConfiguration {
        let image = ImageDescription(
            reference: "folded-name-test.invalid/none:none",
            descriptor: .init(
                mediaType: "application/vnd.oci.image.manifest.v1+json",
                digest: "sha256:" + String(repeating: "0", count: 64),
                size: 0
            )
        )
        let process = ProcessConfiguration(
            executable: "/bin/true",
            arguments: [],
            environment: [],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0),
            supplementalGroups: [],
            rlimits: []
        )
        var configuration = ContainerConfiguration(id: id, image: image, process: process)
        configuration.networks = []
        return configuration
    }

    private var kernel: Kernel {
        Kernel(path: URL(fileURLWithPath: "/nonexistent/kernel"), platform: .linuxArm)
    }

    /// Writes the on-disk state of a container as `create` leaves it, into `containers/<directory>`:
    /// the runtime configuration of `runtimeID`, the bundle configuration of `bundleID` when given
    /// (a container that was started once), and a stand-in for its writable root file system.
    private func writeContainer(appRoot: FilePath, directory: String, runtimeID: String, bundleID: String?) throws -> URL {
        let path = URL(fileURLWithPath: appRoot.appending("containers").appending(directory).string)
        let runtime = RuntimeConfiguration(
            path: path,
            initialFilesystem: .block(format: "ext4", source: "/nonexistent/initfs", destination: "/", options: []),
            kernel: kernel,
            containerConfiguration: configuration(id: runtimeID)
        )
        try runtime.writeRuntimeConfiguration()
        if let bundleID {
            try ContainerResource.Bundle(path: path).set(configuration: configuration(id: bundleID))
        }
        try Data("data the container wrote".utf8).write(to: path.appendingPathComponent("rootfs.ext4"))
        return path
    }

    private func contents(of directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            result[name] = try Data(contentsOf: directory.appendingPathComponent(name))
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
        "a create whose name the file system folds onto an existing container is refused before anything is written",
        .enabled(if: tempDirIsCaseInsensitive(), "needs a case-insensitive temporary directory")
    )
    func createRefusesAFoldedName() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "cfold", runtimeID: "cfold", bundleID: "cfold")
            let before = try contents(of: directory)
            let service = try makeService(appRoot: appRoot)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.create(
                    configuration: configuration(id: "CFOLD"),
                    kernel: kernel,
                    options: ContainerCreateOptions(autoRemove: false),
                    initImage: "folded-name-test.invalid/none:none"
                )
            }
            #expect(error?.code == .exists)
            #expect(error?.message.contains("'cfold'") == true)
            #expect(try contents(of: directory) == before)
            #expect(try await service.list().map(\.id) == ["cfold"])
        }
    }

    @Test("a directory whose bundle and runtime configuration name two containers is kept, and its delete is refused")
    func sharedDirectoryIsKept() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "cmix", runtimeID: "CMIX", bundleID: "cmix")
            let before = try contents(of: directory)
            let service = try makeService(appRoot: appRoot)

            #expect(try await service.list().map(\.id) == ["cmix"])
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: "cmix", force: true)
            }
            #expect(error?.code == .invalidState)
            #expect(try contents(of: directory) == before)
        }
    }

    @Test("a directory whose name differs from the container it holds is kept, and its delete is refused")
    func renamedDirectoryIsKept() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "cdir", runtimeID: "CDIR", bundleID: nil)
            let before = try contents(of: directory)
            let service = try makeService(appRoot: appRoot)

            #expect(try await service.list().map(\.id) == ["CDIR"])
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: "CDIR", force: true)
            }
            #expect(error?.code == .invalidState)
            #expect(try contents(of: directory) == before)
        }
    }

    @Test("a container whose directory holds only its own configuration still deletes")
    func ordinaryContainerDeletes() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "cok", runtimeID: "cok", bundleID: "cok")
            let service = try makeService(appRoot: appRoot)

            try await service.delete(id: "cok", force: true)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(try await service.list().isEmpty)
        }
    }
}

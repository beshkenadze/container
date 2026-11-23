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
import Containerization
import ContainerizationError
import Foundation
import Logging
import Testing

/// A container create writes only into a directory that it made: it never writes into the
/// directory of a container whose name the file system folds onto the same entry.
struct ContainerCreateFoldedNameTests {
    private static let runtimeName = "container-runtime-linux"
    private let log = Logger(label: "test")

    private static let runtimeConfig = """
        abstract = "test runtime"

        [servicesConfig]
        loadAtBoot = false
        runAtLoad = false
        defaultArguments = []

        [[servicesConfig.services]]
        type = "runtime"
        """

    private func makeService(appRoot: URL) async throws -> ContainersService {
        let plugins = appRoot.appendingPathComponent("plugins")
        let plugin = plugins.appendingPathComponent(Self.runtimeName)
        let bin = plugin.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Self.runtimeConfig.write(to: plugin.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let binary = bin.appendingPathComponent(Self.runtimeName)
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let pluginLoader = try PluginLoader(
            appRoot: appRoot,
            installRoot: appRoot,
            logRoot: nil,
            pluginDirectories: [plugins],
            pluginFactories: [DefaultPluginFactory(logger: log)]
        )
        return try await ContainersService(
            appRoot: appRoot,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log
        )
    }

    private static func configuration(id: String) -> ContainerConfiguration {
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
        return ContainerConfiguration(id: id, image: image, process: process)
    }

    /// Writes the directory of a container that has run: its configuration and its root file system.
    private static func writeContainer(appRoot: URL, id: String) throws -> URL {
        let path = appRoot.appendingPathComponent("containers").appendingPathComponent(id)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let bundle = ContainerResource.Bundle(path: path)
        try bundle.write(filename: "config.json", value: configuration(id: id))
        try bundle.write(filename: "options.json", value: ContainerCreateOptions(autoRemove: false))
        try Data("data the container wrote".utf8).write(to: path.appendingPathComponent("rootfs.ext4"))
        return path
    }

    private static func contents(of directory: URL) throws -> [String: Data] {
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

    private static var options: ContainerCreateOptions {
        ContainerCreateOptions(
            autoRemove: false,
            rootFsOverride: .block(format: "ext4", source: "/nonexistent/rootfs.ext4", destination: "/", options: [])
        )
    }

    private static var kernel: Kernel {
        Kernel(path: URL(fileURLWithPath: "/nonexistent/kernel"), platform: .linuxArm)
    }

    @Test(
        "a create whose name the file system folds onto an existing container is refused and writes nothing",
        .enabled(if: tempDirIsCaseInsensitive(), "needs a case-insensitive temporary directory")
    )
    func createRefusesAFoldedName() async throws {
        try await TemporaryStorage.withTempDir { root in
            let appRoot = URL(fileURLWithPath: root.string)
            let directory = try Self.writeContainer(appRoot: appRoot, id: "cfold")
            let before = try Self.contents(of: directory)
            let service = try await makeService(appRoot: appRoot)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.create(
                    configuration: Self.configuration(id: "CFOLD"),
                    kernel: Self.kernel,
                    options: Self.options,
                    initImage: "folded-name-test.invalid/init:none"
                )
            }
            #expect(error?.code == .invalidArgument)
            #expect(error?.message.contains("'cfold'") == true)
            #expect(try Self.contents(of: directory) == before)
            #expect(try await service.list().map(\.id) == ["cfold"])
        }
    }

    @Test("a create does not write into a directory that holds files and belongs to no container")
    func createRefusesADirectoryWithFiles() async throws {
        try await TemporaryStorage.withTempDir { root in
            let appRoot = URL(fileURLWithPath: root.string)
            let service = try await makeService(appRoot: appRoot)
            let directory = appRoot.appendingPathComponent("containers").appendingPathComponent("cheld")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("data the container wrote".utf8).write(to: directory.appendingPathComponent("rootfs.ext4"))
            let before = try Self.contents(of: directory)

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.create(
                    configuration: Self.configuration(id: "cheld"),
                    kernel: Self.kernel,
                    options: Self.options,
                    initImage: "folded-name-test.invalid/init:none"
                )
            }
            #expect(error?.code == .invalidState)
            // The suggested place is outside the directory that the server scans at startup.
            #expect(error?.message.contains("move the directory out of \(directory.deletingLastPathComponent().path)") == true)
            // A shell command in the message breaks on quotes in the path and on long names.
            #expect(error?.message.contains("`mv ") == false)
            #expect(try Self.contents(of: directory) == before)
            #expect(try await service.list().isEmpty)
        }
    }
}

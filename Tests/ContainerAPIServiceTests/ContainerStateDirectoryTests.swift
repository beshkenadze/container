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
import Synchronization
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

    /// The launchd labels that the service asked to boot out. Nothing reaches launchd.
    private final class Bootouts: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String] = []
        func record(_ label: String) { lock.withLock { labels.append(label) } }
        var all: [String] { lock.withLock { labels } }
    }

    /// Host effects for tests: boot-outs are recorded, the init block is a file under the test root.
    private func hostEffects(appRoot: FilePath, bootouts: Bootouts) -> ContainersService.HostEffects {
        let initBlock = appRoot.appending("initfs.ext4").string
        return ContainersService.HostEffects(
            deregister: { label in
                bootouts.record(label)
                return 0
            },
            initBlock: { _, _ in
                FileManager.default.createFile(atPath: initBlock, contents: Data("initfs".utf8))
                return .block(format: "ext4", source: initBlock, destination: "/", options: ["ro"])
            }
        )
    }

    private func makeService(
        appRoot: FilePath, bootouts: Bootouts = Bootouts(), runtimePlugin: Bool = true, effects: ContainersService.HostEffects? = nil
    ) throws -> ContainersService {
        let appURL = URL(fileURLWithPath: appRoot.string)
        let plugins = appURL.appendingPathComponent("plugins")
        try FileManager.default.createDirectory(
            at: plugins.appendingPathComponent("container-runtime-linux"), withIntermediateDirectories: true)
        let pluginLoader = try PluginLoader(
            appRoot: appURL,
            installRoot: appURL,
            logRoot: nil,
            pluginDirectories: [plugins],
            pluginFactories: runtimePlugin ? [RuntimePluginFactory()] : []
        )
        return try ContainersService(
            appRoot: appURL,
            pluginLoader: pluginLoader,
            containerSystemConfig: ContainerSystemConfig(),
            log: log,
            hostEffects: effects ?? hostEffects(appRoot: appRoot, bootouts: bootouts)
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
                // The init block and the root file system come from the test, so on the old code
                // this create runs to its write into the existing directory.
                try await service.create(
                    configuration: configuration(id: "CFOLD"),
                    kernel: kernel,
                    options: ContainerCreateOptions(
                        autoRemove: false,
                        rootFsOverride: .block(
                            format: "ext4", source: appRoot.appending("rootfs-override.ext4").string, destination: "/", options: [])),
                    initImage: nil
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

    @Test(
        "a healthy container whose directory name differs only in case loads and deletes",
        .enabled(if: tempDirIsCaseInsensitive(), "needs a case-insensitive temporary directory"),
        arguments: [true, false]
    )
    func caseRenamedDirectoryIsHealthy(started: Bool) async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            // Both stored IDs agree; only the directory's spelling differs (a case-only rename, or
            // a container that was never started and has only its runtime configuration).
            let directory = try writeContainer(appRoot: appRoot, directory: "webdir", runtimeID: "WebDir", bundleID: started ? "WebDir" : nil)
            let service = try makeService(appRoot: appRoot)

            #expect(try await service.list().map(\.id) == ["WebDir"])
            try await service.delete(id: "WebDir", force: true)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
    }

    @Test("a directory that its container's ID does not lead to is kept, and its delete is refused")
    func unreachableDirectoryIsKept() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "xdir", runtimeID: "ydir", bundleID: "ydir")
            let before = try contents(of: directory)
            let service = try makeService(appRoot: appRoot)

            #expect(try await service.list().map(\.id) == ["ydir"])
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.delete(id: "ydir", force: true)
            }
            #expect(error?.code == .invalidState)
            #expect(try contents(of: directory) == before)
        }
    }

    @Test("a container whose directory holds only its own configuration still deletes, and only its label is booted out")
    func ordinaryContainerDeletes() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "cok", runtimeID: "cok", bundleID: "cok")
            let bootouts = Bootouts()
            let service = try makeService(appRoot: appRoot, bootouts: bootouts)

            try await service.delete(id: "cok", force: true)
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(try await service.list().isEmpty)
            #expect(bootouts.all.count == 1 && bootouts.all[0].hasSuffix(".container-runtime-linux.cok"))
        }
    }

    @Test("a container directory that an interrupted create left empty does not block the name; one with files does")
    func abandonedDirectoryIsReclaimedAtCreate() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let service = try makeService(appRoot: appRoot)
            let containers = appRoot.appending("containers")
            try FileManager.default.createDirectory(atPath: containers.appending("cleft").string, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: containers.appending("cheld").string, withIntermediateDirectories: true)
            try Data("rootfs".utf8).write(to: URL(fileURLWithPath: containers.appending("cheld").appending("rootfs.ext4").string))
            let options = ContainerCreateOptions(
                autoRemove: false,
                rootFsOverride: .block(format: "ext4", source: appRoot.appending("rootfs-override.ext4").string, destination: "/", options: []))

            try await service.create(configuration: configuration(id: "cleft"), kernel: kernel, options: options, initImage: nil)
            #expect(try await service.list().map(\.id) == ["cleft"])
            #expect(!FileManager.default.fileExists(atPath: containers.appending("cleft").appending(ReservedDirectory.markerName).string))

            let error = await #expect(throws: ContainerizationError.self) {
                try await service.create(configuration: configuration(id: "cheld"), kernel: kernel, options: options, initImage: nil)
            }
            #expect(error?.code == .exists)
            #expect(error?.message.contains(containers.appending("cheld").string) == true)
            #expect(FileManager.default.fileExists(atPath: containers.appending("cheld").appending("rootfs.ext4").string))
        }
    }

    @Test("a container whose runtime plugin is gone is listed and its directory stays")
    func missingRuntimePluginKeepsTheBundle() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = try writeContainer(appRoot: appRoot, directory: "cplug", runtimeID: "cplug", bundleID: "cplug")
            let before = try contents(of: directory)
            let service = try makeService(appRoot: appRoot, runtimePlugin: false)

            #expect(try contents(of: directory) == before)
            #expect(try await service.list().map(\.id) == ["cplug"])
            // Its start reports the missing plugin; it does not stop the service.
            let error = await #expect(throws: ContainerizationError.self) {
                try await service.bootstrap(id: "cplug", stdio: [nil, nil, nil], dynamicEnv: [:])
            }
            #expect(error?.code == .notFound)
            #expect(try contents(of: directory) == before)
        }
    }

    @Test("a directory whose configurations cannot be read stays")
    func unreadableDirectoryStays() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let directory = URL(fileURLWithPath: appRoot.appending("containers").appending("cbad").string)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{ not json".utf8).write(to: directory.appendingPathComponent("config.json"))
            try Data("data the container wrote".utf8).write(to: directory.appendingPathComponent("rootfs.ext4"))
            let before = try contents(of: directory)
            let service = try makeService(appRoot: appRoot)

            #expect(try contents(of: directory) == before)
            #expect(try await service.list().isEmpty)
        }
    }

    @Test("a delete that waited behind a replacement of its container does not remove the replacement")
    func staleDeleteKeepsTheReplacement() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            _ = try writeContainer(appRoot: appRoot, directory: "w", runtimeID: "w", bundleID: "w")
            let service = try makeService(appRoot: appRoot)
            let options = ContainerCreateOptions(
                autoRemove: false,
                rootFsOverride: .block(format: "ext4", source: appRoot.appending("rootfs-override.ext4").string, destination: "/", options: []))

            // Hold the service lock, then queue in this order: delete, create of a replacement
            // under the same name, delete. Both deletes read the original's state before they wait.
            let (gate, open) = AsyncStream<Void>.makeStream()
            let holder = Task { try await service.withContainerList(logMetadata: [:]) { _ in for await _ in gate { break } } }
            let pause = Duration.milliseconds(200)
            try await Task.sleep(for: pause)
            let first = Task { try await service.delete(id: "w", force: false) }
            try await Task.sleep(for: pause)
            let replacement = configuration(id: "w")
            let create = Task { try await service.create(configuration: replacement, kernel: kernel, options: options, initImage: nil) }
            try await Task.sleep(for: pause)
            let second = Task { try await service.delete(id: "w", force: false) }
            try await Task.sleep(for: pause)
            open.yield()
            open.finish()
            try await holder.value

            try await first.value
            try await create.value
            let error = await #expect(throws: ContainerizationError.self) { try await second.value }
            #expect(error?.code == .notFound)
            let listed = try await service.list()
            #expect(listed.map(\.id) == ["w"])
            #expect(listed.first?.configuration.creationDate == replacement.creationDate)
            #expect(FileManager.default.fileExists(atPath: appRoot.appending("containers/w").string))
        }
    }

    @Test("a second create of a name waits for the first; when the first fails, the second's bundle stays")
    func failingCreateLeavesTheNextOne() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            let (gate, open) = AsyncStream<Void>.makeStream()
            let calls = Mutex(0)
            let initBlock = appRoot.appending("initfs.ext4").string
            FileManager.default.createFile(atPath: initBlock, contents: Data("initfs".utf8))
            let effects = ContainersService.HostEffects(
                deregister: { _ in 0 },
                initBlock: { _, _ in
                    // The first create waits in its init-image fetch, then fails.
                    if calls.withLock({ count in
                        count += 1
                        return count
                    }) == 1 {
                        for await _ in gate { break }
                        throw ContainerizationError(.internalError, message: "fetch failed")
                    }
                    return .block(format: "ext4", source: initBlock, destination: "/", options: ["ro"])
                })
            let service = try makeService(appRoot: appRoot, effects: effects)
            let options = ContainerCreateOptions(
                autoRemove: false,
                rootFsOverride: .block(format: "ext4", source: appRoot.appending("rootfs-override.ext4").string, destination: "/", options: []))

            let first = Task { try await service.create(configuration: configuration(id: "same"), kernel: kernel, options: options, initImage: nil) }
            let pause = Duration.milliseconds(200)
            try await Task.sleep(for: pause)
            let second = Task { try await service.create(configuration: configuration(id: "same"), kernel: kernel, options: options, initImage: nil) }
            try await Task.sleep(for: pause)
            open.yield()
            open.finish()

            await #expect(throws: ContainerizationError.self) { try await first.value }
            try await second.value
            #expect(try await service.list().map(\.id) == ["same"])
            #expect(FileManager.default.fileExists(atPath: appRoot.appending("containers/same/runtime-configuration.json").string))
        }
    }

    @Test("a healthy container reached through a symbolic link named after it is not quarantined")
    func bundleBehindASymlinkIsHealthy() async throws {
        try await TemporaryStorage.withTempDir { appRoot in
            _ = try writeContainer(appRoot: appRoot, directory: "stored", runtimeID: "Web", bundleID: "Web")
            try FileManager.default.createSymbolicLink(
                atPath: appRoot.appending("containers/Web").string, withDestinationPath: appRoot.appending("containers/stored").string)
            let service = try makeService(appRoot: appRoot)

            #expect(try await service.list().map(\.id) == ["Web"])
            try await service.delete(id: "Web", force: true)
        }
    }
}

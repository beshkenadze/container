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

import ContainerResource
import ContainerizationError
import Foundation
import Testing

@testable import ContainerAPIClient

/// `run -v name:/path` creates the volume, or uses the one that already exists.
struct ExistingVolumeTests {
    private let volume = VolumeConfiguration(name: "data", source: "/vols/data/volume.img")

    @Test("an exact name that exists is used")
    func exactNameIsUsed() async throws {
        let wrapped = ContainerizationError(.invalidArgument, message: "volume 'data' already exists")
        let found = try await Utility.existingVolume(after: wrapped) { volume }
        #expect(found.name == "data")
        let typed = try await Utility.existingVolume(after: VolumeError.volumeAlreadyExists("data")) { volume }
        #expect(typed.name == "data")
    }

    @Test("a name that exists under another spelling gives the conflict, not \"not found\"")
    func foldedNameGivesTheConflict() async throws {
        let conflict = ContainerizationError(.exists, message: "volume 'data' already exists as 'Data': on this file system the two names are the same")
        let error = await #expect(throws: ContainerizationError.self) {
            _ = try await Utility.existingVolume(after: conflict) { throw VolumeError.volumeNotFound("data") }
        }
        #expect(error?.code == .exists)
        #expect(error?.message.contains("as 'Data'") == true)
    }

    @Test("any other create error is thrown as it is")
    func otherErrorsPassThrough() async throws {
        let other = ContainerizationError(.internalError, message: "disk full")
        await #expect(throws: ContainerizationError.self) {
            _ = try await Utility.existingVolume(after: other) {
                Issue.record("inspected")
                return volume
            }
        }
    }

    @Test("an inspect that fails for another reason than not-found is reported as it is")
    func otherInspectErrorsPassThrough() async throws {
        let conflict = ContainerizationError(.exists, message: "volume 'data' already exists as 'Data': on this file system the two names are the same")
        let dropped = ContainerizationError(.interrupted, message: "XPC connection interrupted")
        let error = await #expect(throws: ContainerizationError.self) {
            _ = try await Utility.existingVolume(after: conflict) { throw dropped }
        }
        #expect(error?.code == .interrupted)
    }
}

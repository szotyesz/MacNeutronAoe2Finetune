import Foundation
import Testing
@testable import MacNeutronCore

@Test func defaultsToDXMT() {
    let choice = GraphicsBackend.select(requested: nil)
    #expect(choice.backend == .dxmt)
    #expect(choice.note == nil)
}

@Test func removedBackendReadsAsTheDefaultWithANote() {
    let choice = GraphicsBackend.select(requested: "d3dmetal")
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "'d3dmetal' was removed in 0.1, using dxmt")
    let aoe2 = GraphicsBackend.select(requested: "d3dmetal", appID: "813780")
    #expect(aoe2.backend == .dxvk)
    #expect(aoe2.note == "'d3dmetal' was removed in 0.1, using dxvk")
}

@Test func ageOfEmpiresIIDefaultsToDXVK() {
    #expect(GraphicsBackend.select(requested: nil, appID: "813780") == (.dxvk, nil))
    #expect(GraphicsBackend.select(requested: nil, appID: "42") == (.dxmt, nil))
    #expect(GraphicsBackend.select(requested: "dxmt", appID: "813780") == (.dxmt, nil))  // a choice wins
    #expect(GraphicsBackend.select(requested: "DXVK", appID: "42") == (.dxvk, nil))
}

@Test func overrideStringsPerBackend() {
    #expect(GraphicsBackend.dxmt.dllOverrides == "dxgi,d3d10core,d3d11,d3d12=n,b;d3d9,d3d10=b")
    #expect(GraphicsBackend.dxvk.dllOverrides == "dxgi,d3d10core,d3d11=n,b;d3d9,d3d10,d3d12=b")
    #expect(GraphicsBackend.wined3d.dllOverrides == "dxgi,d3d9,d3d10,d3d10core,d3d11,d3d12=b")
}

@Test func honorsRequestCaseInsensitively() {
    let choice = GraphicsBackend.select(requested: " WINED3D ")
    #expect(choice.backend == .wined3d)
    #expect(choice.note == nil)
}

@Test func unknownRequestFallsBackWithNote() {
    let choice = GraphicsBackend.select(requested: "vulkan")
    #expect(choice.backend == .dxmt)
    #expect(choice.note == "unknown MACNEUTRON_GRAPHICS 'vulkan', using dxmt")
}

@Test func everyBackendOverridesTheSameDLLSet() {
    let managed: Set = ["dxgi", "d3d9", "d3d10", "d3d10core", "d3d11", "d3d12"]
    for backend in GraphicsBackend.allCases {
        let names = backend.dllOverrides.split(separator: ";").flatMap {
            $0.split(separator: "=")[0].split(separator: ",").map(String.init)
        }
        #expect(Set(names) == managed, "\(backend)")
        #expect(names.count == managed.count, "\(backend) repeats a DLL")
    }
}

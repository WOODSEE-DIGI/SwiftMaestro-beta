import Foundation
import Testing
@testable import SwiftMaestro

/// Guards the root cause of the "Clear Chat does nothing" bug: the cache used
/// to be a replaceable `static var shared?` that every ContentView construction
/// overwrote, so a view displaying a VM from an older cache instance could
/// never be cleared through the current `shared`. Now a non-optional
/// `static let`, the cache can neither be nil nor replaced — and
/// `viewModel(for:)` must always return the SAME instance for the same agent.
@MainActor
struct ChatViewModelCacheTests {

    @Test func sameAgentAlwaysResolvesToSameViewModel() {
        let agent = AgentRecord(name: "CacheIdentityTest", kind: .project)
        let vm1 = ChatViewModelCache.shared.viewModel(for: agent, projectName: nil)
        let vm2 = ChatViewModelCache.shared.viewModel(for: agent, projectName: nil)
        #expect(vm1 === vm2)
        ChatViewModelCache.shared.drop(agent.id)
    }

    @Test func differentAgentsGetDifferentViewModels() {
        let a = AgentRecord(name: "CacheTestA", kind: .project)
        let b = AgentRecord(name: "CacheTestB", kind: .project)
        let vmA = ChatViewModelCache.shared.viewModel(for: a, projectName: nil)
        let vmB = ChatViewModelCache.shared.viewModel(for: b, projectName: nil)
        #expect(vmA !== vmB)
        ChatViewModelCache.shared.drop(a.id)
        ChatViewModelCache.shared.drop(b.id)
    }

    @Test func dropForcesFreshViewModelOnNextResolve() {
        let agent = AgentRecord(name: "CacheDropTest", kind: .project)
        let vm1 = ChatViewModelCache.shared.viewModel(for: agent, projectName: nil)
        ChatViewModelCache.shared.drop(agent.id)
        let vm2 = ChatViewModelCache.shared.viewModel(for: agent, projectName: nil)
        #expect(vm1 !== vm2)
        ChatViewModelCache.shared.drop(agent.id)
    }

    @Test func hasViewModelTracksCacheContents() {
        let agent = AgentRecord(name: "CacheHasTest", kind: .project)
        #expect(!ChatViewModelCache.shared.hasViewModel(for: agent.id))
        _ = ChatViewModelCache.shared.viewModel(for: agent, projectName: nil)
        #expect(ChatViewModelCache.shared.hasViewModel(for: agent.id))
        ChatViewModelCache.shared.drop(agent.id)
        #expect(!ChatViewModelCache.shared.hasViewModel(for: agent.id))
    }
}

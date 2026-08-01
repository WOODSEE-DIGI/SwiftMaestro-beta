import XCTest
@testable import SwiftMaestro

/// Tests for the agent category taxonomy and model-aware prompt generation.
final class AgentCategoryTests: XCTestCase {

    // MARK: - Category inference

    func testInferCodingFromName() {
        XCTAssertEqual(AgentCategory.infer(from: "Swift Developer"), .coding)
        XCTAssertEqual(AgentCategory.infer(from: "Frontend Engineer"), .coding)
        XCTAssertEqual(AgentCategory.infer(from: "Python Coder"), .coding)
    }

    func testInferDesignFromName() {
        XCTAssertEqual(AgentCategory.infer(from: "UI Designer"), .design)
        XCTAssertEqual(AgentCategory.infer(from: "Visual Graphic"), .design)
    }

    func testInferResearchFromName() {
        XCTAssertEqual(AgentCategory.infer(from: "Web Researcher"), .research)
    }

    func testInferFallsBackToGeneral() {
        XCTAssertEqual(AgentCategory.infer(from: "Helper"), .general)
    }

    func testDefaultAgentNamesMapToExpectedCategories() {
        let expected: [(String, AgentCategory)] = [
            ("Generalist", .general),
            ("SwiftCoder", .coding),
            ("ResearchScout", .research),
            ("Analyst", .analysis),
            ("Builder", .create),
            ("TechWriter", .writing),
            ("Designer", .design),
            ("DevOps", .devops),
            ("Tester", .testing),
            ("DataScientist", .data),
            ("Marketer", .marketing),
            ("LegalAnalysis", .legal),
            ("FinanceAnalyst", .finance),
        ]
        for (name, category) in expected {
            XCTAssertEqual(AgentCategory.infer(from: name), category, "\(name) should infer to \(category)")
        }
    }

    func testDefaultAgentNamesAreUniqueAndCountThirteen() {
        XCTAssertEqual(Agent.defaultAgentNames.count, 13)
        XCTAssertEqual(Set(Agent.defaultAgentNames).count, 13)
    }

    func testLegalAgentPromptDoesNotProvideLegalAdvice() {
        let prompt = AgentCategory.legal.promptSection(agentName: "LegalAnalysis", modelID: "mlx-community/Qwen3.5-122B-A10B-4bit")
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("SIDEBAR CATEGORY: Legal") == true)
        XCTAssertTrue(prompt?.contains("not a lawyer") == true)
        XCTAssertTrue(prompt?.contains("do not provide legal advice") == true)
        XCTAssertTrue(prompt?.contains("attorney-client relationship") == true)
    }

    // MARK: - Model flavor classification

    func testModelFlavorLarge() {
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/Qwen3.5-122B-A10B-4bit"), .large)
        XCTAssertEqual(ModelFlavor(modelID: "Qwen3.5-122B-A10B"), .large)
        XCTAssertEqual(ModelFlavor(modelID: "Meta-Llama-3.1-70B-Instruct"), .large)
    }

    func testModelFlavorBalanced() {
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/Qwen3.6-35B-A3B-MLX-4bit"), .balanced)
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/Qwen3-Coder-Next-4bit"), .balanced)
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/Qwen3.5-27B-A3B"), .balanced)
    }

    func testModelFlavorSmall() {
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/gemma-4-26B-A4B-8bit"), .small)
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/Qwen3-VL-8B-Instruct-4bit"), .small)
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/Llama-3.1-8B-Instruct"), .small)
        XCTAssertEqual(ModelFlavor(modelID: "mlx-community/FastVLM-0.5B-bf16"), .small)
    }

    // MARK: - Category prompt generation

    func testCodingPromptIncludesModelFlavor() {
        let large = AgentCategory.coding.promptSection(agentName: "CodeBuilder", modelID: "mlx-community/Qwen3.5-122B-A10B-4bit")
        XCTAssertNotNil(large)
        XCTAssertTrue(large?.contains("CODING AGENT MODE") == true)
        XCTAssertTrue(large?.contains("MODEL CAPACITY: You are running on a large, capable model") == true)
        XCTAssertTrue(large?.contains("3 tool calls per turn") == true)

        let small = AgentCategory.coding.promptSection(agentName: "CodeBuilder", modelID: "mlx-community/gemma-4-26B-A4B-8bit")
        XCTAssertTrue(small?.contains("MODEL CAPACITY: You are running on a smaller model") == true)
        XCTAssertTrue(small?.contains("ONE tool per turn") == true)
    }

    func testCodingPromptUnknownFlavor() {
        let prompt = AgentCategory.coding.promptSection(agentName: "CodeBuilder", modelID: nil)
        XCTAssertTrue(prompt?.contains("MODEL CAPACITY: You are running on a smaller model") == true)
    }

    func testNonCodingPromptsDoNotContainFlavor() {
        let research = AgentCategory.research.promptSection(agentName: "Researcher", modelID: "mlx-community/Qwen3.5-122B-A10B-4bit")
        XCTAssertTrue(research?.contains("RESEARCH AGENT MODE") == true)
        XCTAssertFalse(research?.contains("MODEL CAPACITY") == true)
    }

    func testGeneralPromptIncludesCategory() {
        let prompt = AgentCategory.general.promptSection(agentName: "Helper", modelID: "mlx-community/Qwen3.5-122B-A10B-4bit")
        XCTAssertNotNil(prompt)
        XCTAssertTrue(prompt?.contains("SIDEBAR CATEGORY: General") == true)
    }

    func testDefaultToolCategoriesForCoding() {
        let categories = AgentCategory.coding.defaultToolCategories
        XCTAssertTrue(categories.contains(.file))
        XCTAssertTrue(categories.contains(.shell))
        XCTAssertTrue(categories.contains(.index))
        XCTAssertTrue(categories.contains(.sqlite))
    }

    func testDefaultToolCategoriesForGeneral() {
        let categories = AgentCategory.general.defaultToolCategories
        XCTAssertTrue(categories.contains(.file))
        XCTAssertTrue(categories.contains(.bus))
        XCTAssertTrue(categories.contains(.rules))
    }

    // MARK: - Budgets

    func testResearchHasGenerousRoundBackstop() {
        XCTAssertEqual(AgentCategory.research.maxRounds, 100)
    }

    func testResearchHasGenerousWebSearchBackstop() {
        XCTAssertEqual(AgentCategory.research.maxToolCallsPerTool["web_search"], 25)
    }

    func testCodingHasNoPerToolCaps() {
        XCTAssertTrue(AgentCategory.coding.maxToolCallsPerTool.isEmpty)
    }

    func testResearchPromptHasNoHardSearchBudget() {
        let prompt = AgentCategory.research.promptSection(agentName: "Researcher", modelID: "mlx-community/gemma-4-26B-A4B-8bit")
        XCTAssertTrue(prompt?.contains("no fixed search budget") == true)
        XCTAssertFalse(prompt?.contains("more than 3 times") == true)
    }
}

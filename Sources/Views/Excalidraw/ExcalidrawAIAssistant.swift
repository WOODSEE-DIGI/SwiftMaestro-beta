import Foundation
import MLXLMCommon
import SwiftMaestroKit

// MARK: - Errors

enum ExcalidrawAIError: LocalizedError {
    case noModel
    case noBoardCreated
    case notToolCapable
    case cancelled
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .noModel:
            return "No model is selected. Choose a model in Settings → Models."
        case .noBoardCreated:
            return "The agent did not create or update an Excalidraw board."
        case .notToolCapable:
            return "The selected model does not advertise tool calling. Choose a tool-capable model (e.g. Qwen 3.5 122B, Qwen 3.6 35B, or Gemma 4 26B)."
        case .cancelled:
            return "Generation was cancelled."
        case .underlying(let error):
            return error.localizedDescription
        }
    }
}

// MARK: - Excalidraw AI Assistant

/// Runs SwiftMaestro's local model against Excalidraw's "Text to diagram" and
/// "Wireframe to code" features, replacing Excalidraw's cloud AI with the
/// in-process MLX backend or a configured remote LM Studio endpoint.
@MainActor
final class ExcalidrawAIAssistant {
    private let engine: MLXInferenceEngine
    private let catalog: ModelCatalog

    init(engine: MLXInferenceEngine, catalog: ModelCatalog) {
        self.engine = engine
        self.catalog = catalog
    }

    // MARK: - Text to diagram

    /// Runs a headless agent that builds a diagram from a natural-language
    /// description using the existing `excalidraw_*` tool surface.
    /// - Returns: The board that was created or updated.
    func generateDiagram(from description: String) async throws -> ExcalidrawBoard {
        guard let model = catalog.selectedModel ?? catalog.models.first else {
            throw ExcalidrawAIError.noModel
        }
        guard model.advertisesTools else {
            throw ExcalidrawAIError.notToolCapable
        }

        let boardName = "AI Diagram \(Self.dateSuffix())"
        try ExcalidrawStore.shared.saveBoard(
            name: boardName,
            data: Self.emptyExcalidrawSceneJSON())

        guard let board = ExcalidrawStore.shared.listBoards()
            .first(where: { $0.name.caseInsensitiveCompare(boardName) == .orderedSame })
        else {
            throw ExcalidrawAIError.noBoardCreated
        }

        let backend = ChatViewModel.makeBackend(
            for: model,
            engine: engine,
            sessionKey: "excalidraw-ai-\(UUID().uuidString)")
        let executor = AgentExecutor(
            modelID: model.huggingFaceID,
            backend: backend)

        let toolSpecs = await MaestroTools.schemas(
            navigator: false,
            enabledCategories: [.excalidraw])

        let systemPrompt = """
        You are an expert diagram designer inside SwiftMaestro's Excalidraw editor.
        The user has described a diagram. Build it on the Excalidraw board named \"\(boardName)\".

        Rules:
        - Always pass board: \"\(boardName)\" to every excalidraw tool call.
        - Use excalidraw_create_board only if that exact board does not exist.
        - Use excalidraw_add_shape for nodes. Shape guide:
          - rectangle = process/step
          - diamond = decision
          - roundedRectangle = start/end
          - ellipse = terminator, cloud, or loose concept
          - circle = small state/bullet
        - Use excalidraw_add_text for titles or annotations that should NOT be inside a shape.
        - Use excalidraw_connect for arrows between nodes. Label decision arrows with \"yes\"/\"no\" when appropriate.
        - Layout the diagram in a clean top-to-bottom or left-to-right flow.
        - Keep labels concise (1-4 words). Use short phrases.
        - If the request is a flowchart, start with a roundedRectangle, then rectangles, diamonds for decisions, and a roundedRectangle for end.
        - After building the diagram, respond with a single sentence naming the diagram and confirming completion. Do not ask follow-up questions.
        """

        let messages: [Message] = [
            Message(role: .system, content: systemPrompt),
            Message(role: .user, content: description)
        ]

        let stream = executor.run(
            messages: messages,
            toolSpecs: toolSpecs,
            mcp: engine.mcpService,
            engine: engine,
            catalog: catalog,
            temperature: min(model.tunedTemperature, 0.3),
            topP: model.tunedTopP,
            thinkingEnabled: model.tunedThinkingEnabled,
            project: nil,
            workingDirectory: nil,
            agentID: "excalidraw-ai",
            maxRounds: 25,
            maxTokens: model.tunedMaxTokens
        )

        for try await _ in stream {
            try Task.checkCancellation()
        }

        // Refresh to pick up any changes the agent wrote.
        if let updated = ExcalidrawStore.shared.listBoards()
            .first(where: { $0.url.standardizedFileURL == board.url.standardizedFileURL }) {
            return updated
        }
        throw ExcalidrawAIError.noBoardCreated
    }

    // MARK: - Wireframe to code

    /// Generates an HTML/CSS implementation of the current Excalidraw scene.
    /// - Parameters:
    ///   - sceneJSON: The Excalidraw scene JSON exported from the editor.
    ///   - instructions: Optional extra instructions (e.g. "use Tailwind", "make it React").
    /// - Returns: Generated code string.
    func generateCode(from sceneJSON: String, instructions: String?) async throws -> String {
        guard let model = catalog.selectedModel ?? catalog.models.first else {
            throw ExcalidrawAIError.noModel
        }

        let backend = ChatViewModel.makeBackend(
            for: model,
            engine: engine,
            sessionKey: "excalidraw-code-\(UUID().uuidString)")
        let executor = AgentExecutor(
            modelID: model.huggingFaceID,
            backend: backend)

        let systemPrompt = """
        You are an expert frontend developer. Convert the provided Excalidraw wireframe scene JSON into clean, self-contained HTML/CSS code.

        Rules:
        - Output a complete, single-file HTML page.
        - Use the text labels, shapes, and relative positions from the Excalidraw JSON to guide the layout.
        - Use CSS flexbox/grid and absolute positioning where appropriate to approximate the wireframe.
        - Preserve colors and approximate sizes when they are present in the JSON.
        - Make the result responsive where possible, but prioritize matching the wireframe.
        - Output ONLY the HTML/CSS code. No markdown fences, no explanations, no commentary.
        """

        var userContent = "Convert this Excalidraw wireframe scene into HTML/CSS:\n\n```json\n\(sceneJSON)\n```"
        if let instructions, !instructions.isEmpty {
            userContent += "\n\nAdditional instructions: \(instructions)"
        }

        let messages: [Message] = [
            Message(role: .system, content: systemPrompt),
            Message(role: .user, content: userContent)
        ]

        let stream = executor.run(
            messages: messages,
            toolSpecs: [],
            mcp: nil,
            engine: engine,
            catalog: catalog,
            temperature: model.tunedTemperature,
            topP: model.tunedTopP,
            thinkingEnabled: false,
            project: nil,
            workingDirectory: nil,
            agentID: "excalidraw-code",
            maxRounds: 1,
            maxTokens: model.tunedMaxTokens
        )

        var code = ""
        for try await output in stream {
            try Task.checkCancellation()
            if case .token(let token) = output {
                code += token
            }
        }

        // Strip any stray markdown fences the model may have emitted.
        code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("```html"), let end = code.range(of: "```", options: .backwards) {
            code = String(code[code.index(after: code.firstIndex(of: "\n") ?? code.startIndex)..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if code.hasPrefix("```"), let end = code.range(of: "```", options: .backwards) {
            code = String(code[code.index(after: code.firstIndex(of: "\n") ?? code.startIndex)..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return code
    }

    // MARK: - Helpers

    private static func dateSuffix() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }

    private static func emptyExcalidrawSceneJSON() -> String {
        "{\"type\":\"excalidraw\",\"version\":2,\"source\":\"swiftmaestro\",\"elements\":[],\"appState\":{}}"
    }
}

import Foundation

/// Smart model router that delegates tasks to appropriate models
enum ModelRouter {
    
    enum TaskType {
        case coding
        case reasoning
        case general
        case vision
    }
    
    /// Classify task type from user input
    static func classifyTask(_ prompt: String) -> TaskType {
        let lowercased = prompt.lowercased()
        
        // Coding patterns
        let codingPatterns = [
            "code", "function", "refactor", "debug", "bug", "implement",
            "write code", "swift", "python", "javascript", "typescript",
            "build", "compile", "error", "fix", "create file", "script"
        ]
        
        if codingPatterns.contains(where: { lowercased.contains($0) }) {
            return .coding
        }
        
        // Reasoning patterns
        let reasoningPatterns = [
            "analyze", "explain", "why", "how does", "compare", "evaluate",
            "think about", "reason", "prove", "theorem", "calculate"
        ]
        
        if reasoningPatterns.contains(where: { lowercased.contains($0) }) {
            return .reasoning
        }
        
        // Vision patterns
        let visionPatterns = ["image", "photo", "picture", "visual", "screenshot"]
        if visionPatterns.contains(where: { lowercased.contains($0) }) {
            return .vision
        }
        
        return .general
    }
    
    /// Select appropriate model for task
    static func selectModel(for taskType: TaskType) -> String {
        switch taskType {
        case .coding:
            // Use Qwen Coder 30B for coding tasks
            return LMStudioConfig.codingModel
        case .reasoning:
            // Use 122B for deep reasoning
            return LMStudioConfig.reasoningModel
        case .vision:
            // Use VL model for vision tasks
            return "qwen/qwen3-vl-30b"
        case .general:
            // Use 35B for general tasks (fast)
            return LMStudioConfig.fastModel
        }
    }
    
    /// Route a request to the appropriate model
    static func route(
        messages: [Message],
        prompt: String
    ) -> (model: String, taskType: TaskType) {
        let taskType = classifyTask(prompt)
        let model = selectModel(for: taskType)
        return (model, taskType)
    }
}

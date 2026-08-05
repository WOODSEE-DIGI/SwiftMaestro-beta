import Foundation
import SwiftUI

// MARK: - Subagent category taxonomy
//
// Categories are used to group agents in the sidebar and to apply
// category-specific system prompts and default tool sets.

enum AgentCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case coding = "coding"
    case research = "research"
    case analysis = "analysis"
    case create = "create"
    case writing = "writing"
    case design = "design"
    case devops = "devops"
    case testing = "testing"
    case data = "data"
    case marketing = "marketing"
    case legal = "legal"
    case finance = "finance"
    case general = "general"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coding: return "Coding"
        case .research: return "Research"
        case .analysis: return "Analysis"
        case .create: return "Create"
        case .writing: return "Writing"
        case .design: return "Design"
        case .devops: return "DevOps"
        case .testing: return "Testing"
        case .data: return "Data"
        case .marketing: return "Marketing"
        case .legal: return "Legal"
        case .finance: return "Finance"
        case .general: return "General"
        }
    }

    var systemImage: String {
        switch self {
        case .coding: return "hammer"
        case .research: return "magnifyingglass"
        case .analysis: return "chart.bar"
        case .create: return "paintbrush"
        case .writing: return "pencil"
        case .design: return "photo.artframe"
        case .devops: return "server.rack"
        case .testing: return "checkmark.shield"
        case .data: return "table"
        case .marketing: return "megaphone"
        case .legal: return "building.columns"
        case .finance: return "dollarsign.circle"
        case .general: return "person"
        }
    }

    /// Tool-round backstop for this category's agents. This is NOT a research
    /// limiter — we are fully offline with no token cost, so it is set high and
    /// only forces a final-answer wrap-up on a pathological loop. All categories
    /// share the same generous value so legitimate read→edit→build→verify and
    /// multi-site research/crawl chains are never cut off early.
    var maxRounds: Int {
        switch self {
        case .coding, .testing, .devops: return 100
        case .research, .analysis, .data: return 100
        default: return 100
        }
    }

    /// Per-tool loop backstops. Empty means no per-tool cap. These only fire on a
    /// genuine same-tool runaway, not on normal research — so the values are
    /// deliberately generous (a real crawl/research session can legitimately need
    /// many searches) rather than hard research blockers.
    var maxToolCallsPerTool: [String: Int] {
        switch self {
        case .research: return ["web_search": 25]
        default: return [:]
        }
    }

    /// Default tool categories enabled for agents of this category.
    var defaultToolCategories: Set<ToolCategory> {
        var base: Set<ToolCategory> = [.file, .shell, .memory, .web, .browser, .system, .workspace]
        switch self {
        case .coding:
            base.formUnion([.index, .server, .sqlite, .mcp])
        case .research:
            base.formUnion([.index, .sqlite, .vault])
        case .analysis:
            base.formUnion([.index, .sqlite, .numbers, .vault])
        case .create:
            base.formUnion([.index, .canvas, .notes])
        case .writing:
            base.formUnion([.index, .notes, .vault])
        case .design:
            base.formUnion([.index, .canvas, .photos, .vault])
        case .devops:
            base.formUnion([.index, .server, .sqlite])
        case .testing:
            base.formUnion([.index, .server, .sqlite])
        case .data:
            base.formUnion([.index, .sqlite, .numbers, .vault])
        case .marketing:
            base.formUnion([.index, .notes, .bluesky, .vault])
        case .legal:
            base.formUnion([.index, .notes, .vault])
        case .finance:
            base.formUnion([.index, .sqlite, .numbers, .vault])
        case .general:
            base.formUnion([.index, .messaging, .bus, .rules, .time])
        }
        return base
    }

    /// Heuristic to guess a category from a free-form agent name.
    static func infer(from name: String) -> AgentCategory {
        let lower = name.lowercased()
        let keywords: [(AgentCategory, [String])] = [
            (.coding, ["developer", "coder", "programmer", "engineer", "frontend", "backend", "fullstack", "swift", "python", "web dev", "app dev", "software", "code"]),
            (.design, ["designer", "ui/ux", "ux", "visual", "graphic", "figma", "interface"]),
            (.devops, ["devops", "sre", "ops", "deploy", "infrastructure", "ci/cd", "pipeline"]),
            (.finance, ["finance", "accountant", "budget", "tax"]),
            (.legal, ["legal", "lawyer", "compliance", "contract"]),
            (.analysis, ["analysis", "analyzer", "analyst", "strategist", "evaluate"]),
            (.testing, ["test", "qa", "quality", "automation"]),
            (.data, ["data", "analytics", "ml", "machine learning", "dataset"]),
            (.research, ["research", "researcher", "investigate", "scout"]),
            (.writing, ["writer", "scribe", "copy", "editor", "content", "blog"]),
            (.marketing, ["marketing", "marketer", "seo", "social", "growth", "campaign"]),
            (.create, ["creator", "creative", "artist", "builder", "maker"]),
        ]
        for (category, words) in keywords {
            if words.contains(where: { lower.contains($0) }) {
                return category
            }
        }
        return .general
    }
}

// MARK: - Model capability flavor

/// Rough capability bucket used to adapt category prompts to the underlying model.
/// Extracted from the model's HuggingFace ID or display name.
enum ModelFlavor: Equatable {
    case large      /// 70B+ dense or very capable MoE (e.g., Qwen3.5-122B-A10B).
    case balanced   /// 30B-70B capable models (e.g., Qwen3.6-35B-A3B).
    case small      /// Small MoE, 8B, 7B, 4B, or vision models (e.g., Gemma4-26B-A4B, Qwen3-VL-8B).
    case unknown

    init(model: MaestroModel) {
        if let active = model.activeParamsB {
            if active >= 30 {
                self = .large
                return
            } else if active >= 10 {
                self = .balanced
                return
            } else {
                self = .small
                return
            }
        }
        self = ModelFlavor(modelID: model.huggingFaceID)
    }

    init(modelID: String) {
        let lower = modelID.lowercased()
        // Extract the advertised total parameter size (e.g., 122B, 35B, 8B, 0.5B).
        let totalB = ModelTierPolicy.extractTierB(from: modelID) ?? 0
        // Explicit small-model markers take priority.
        if lower.contains("gemma-4") || lower.contains("gemma4") || lower.contains("fastvlm") || lower.contains("vl-8b") || lower.contains("vl8b") || lower.contains("0.5b") {
            self = .small
            return
        }
        // Balanced models.
        if lower.contains("30b") || lower.contains("35b") || lower.contains("27b") || lower.contains("32b") || lower.contains("coder-next") || (totalB >= 30 && totalB < 70) {
            self = .balanced
            return
        }
        // Large models.
        if lower.contains("122b") || lower.contains("70b") || lower.contains("72b") || lower.contains("110b") || totalB >= 70 {
            self = .large
            return
        }
        // Small models.
        if lower.contains("8b") || lower.contains("7b") || lower.contains("4b") || lower.contains("9b") || totalB < 30 {
            self = .small
            return
        }
        self = .unknown
    }
}

// MARK: - Coding prompt helper

extension AgentCategory {
    /// A system-prompt section tailored to this category and the model's capability.
    /// Returns nil if the category has no special instructions beyond the base prompt.
    func promptSection(
        agentName: String, model: MaestroModel? = nil, modelID: String? = nil
    ) -> String? {
        let flavor: ModelFlavor
        if let model {
            flavor = ModelFlavor(model: model)
        } else if let modelID {
            flavor = ModelFlavor(modelID: modelID)
        } else {
            flavor = .unknown
        }
        let modelNote = (model?.huggingFaceID ?? modelID).map { " (model: \($0))" } ?? ""
        switch self {
        case .coding:
            return codingPrompt(agentName: agentName, modelNote: modelNote, flavor: flavor)
        case .research:
            return """
                RESEARCH AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Research
                You are a research agent. Gather information from the web, local files, and \
                memory. Always cite sources, distinguish facts from speculation, and summarize \
                findings concisely. Use web_search, read_file, and memory tools heavily.
                Search guidance: avoid redundant searches — if a query is not useful, rephrase \
                it rather than repeating the same one. Search as many times as you genuinely need \
                to answer well; there is no fixed search budget.
                Make web_search queries specific enough to avoid ambiguous results. For \
                example, if the topic is the Swift programming language, query "Apple Swift \
                programming language" or "site:swift.org Swift 6.3", not just "Swift". \
                When a term is shared with companies, vehicles, or other domains, add the \
                relevant domain term (e.g., "programming language", "Apple Developer", or \
                "Swift.org").
                """
        case .analysis:
            return """
                ANALYSIS AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Analysis
                You are an analysis agent. Inspect data, logs, code, or documents and extract \
                insights. Prefer structured output, be quantitative where possible, and note \
                uncertainties. Use grep_code, read_file, and data tools as needed.
                """
        case .create:
            return """
                CREATE AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Create
                You are a creative/build agent. Produce new content, prototypes, or assets. \
                Iterate with the user, write files to disk, and use task for parallel creative \
                exploration.
                """
        case .writing:
            return """
                WRITING AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Writing
                You are a writing agent. Draft, edit, and refine text. Maintain the user's \
                voice, check for clarity, and use read_file/write_file to work with documents.
                """
        case .design:
            return """
                DESIGN AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Design
                You are a design agent. Work with visual assets, UI descriptions, and design \
                files. Use file tools to inspect assets and the web to reference design systems.
                """
        case .devops:
            return """
                DEVOPS AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: DevOps
                You are a DevOps agent. Manage deployments, infrastructure, shells, and \
                configuration. Prefer execute_command for shell operations, and be careful with \
                destructive commands.
                """
        case .testing:
            return """
                TESTING AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Testing
                You are a testing/QA agent. Write and run tests, reproduce bugs, and verify \
                fixes. Use shell tools to execute test suites and file tools to inspect test \
                code.
                """
        case .data:
            return """
                DATA AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Data
                You are a data agent. Process, transform, and analyze datasets. Use file tools, \
                SQLite, and shell utilities. Be precise about data shapes and edge cases.
                """
        case .marketing:
            return """
                MARKETING AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Marketing
                You are a marketing agent. Draft campaigns, analyze reach, and produce \
                content. Use web and memory tools to research trends and competitors.
                """
        case .legal:
            return """
                LEGAL AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Legal
                You are a legal/compliance analysis and research assistant. You review documents, \
                contracts, and policies to extract information, summarize clauses, and surface risks \
                for further human review. You are not a lawyer and do not provide legal advice, opinions, \
                or create an attorney-client relationship. Always note when professional legal review is needed.
                """
        case .finance:
            return """
                FINANCE AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: Finance
                You are a finance agent. Analyze budgets, reports, and financial documents. \
                Be precise with numbers and note assumptions.
                """
        case .general:
            return """
                GENERAL AGENT MODE — \(agentName)\(modelNote)
                SIDEBAR CATEGORY: General
                You are a general-purpose assistant. Handle a wide range of tasks, delegate to \
                specialists when appropriate, and use the available tools pragmatically.
                """
        }
    }

    private func codingPrompt(agentName: String, modelNote: String, flavor: ModelFlavor) -> String {
        let commonInstructions = """
            CODING AGENT MODE — \(agentName)\(modelNote)
            SIDEBAR CATEGORY: Coding
            You are a coding/IDE agent. Your job is to read, search, edit, build, and test \
            code like an in-process OpenCode coding assistant. Work inside the project \
            directory and authorized folders only.

            - Use glob_files to discover files by pattern (e.g. 'Sources/**/*.swift', \
            'project.yml', '*.md').
            - If a file path is wrong or read_file returns 'no file', use glob_files or list_dir \
            to find the correct path instead of guessing or looping through alternative locations.
            - Use grep_code to search for symbols, imports, function names, or usages.
            - Use read_file to inspect files. Read multiple files in one turn when possible.
            - When read_file returns the content you asked for, quote it or act on it immediately. \
            Do NOT call read_file again for the same file in the same task unless you need a \
            different section.
            - Use edit_file for precise replacements. The old_string MUST match the file text \
            EXACTLY, including whitespace, indentation, and newlines. For multi-line edits, include \
            enough surrounding context in old_string to make it unique.
            - Worked example — adding a comment after import lines:
              1. read_file(path: "/Users/.../Sources/App/SwiftMaestroApp.swift", limit: 5)
              2. edit_file(
                   path: "/Users/.../Sources/App/SwiftMaestroApp.swift",
                   old_string: "import SwiftUI\nimport SwiftMaestroKit",
                   new_string: "import SwiftUI\nimport SwiftMaestroKit\n\n// SwiftCoder was here"
                 )
              3. read_file(path: "/Users/.../Sources/App/SwiftMaestroApp.swift", limit: 6)
                 to verify the edit.
            - STOP RULE: Once the requested change is done and verified with ONE read_file, do \
            NOT run more tools. Write the final answer immediately and stop. Do not keep listing \
            directories, re-reading the same file, or running commands after the task is complete.
            - Use write_file for creating new files or overwriting large blocks.
            - Use git_status, git_diff, git_log, and git_branch to understand repo state.
            - Use execute_command for builds, tests, and package management. \
            Prefer xcodebuild for Xcode projects, swift build for SPM packages, and xcodegen \
            generate when project.yml changes.
            - Use task to spin up a temporary specialist for parallel exploration or analysis.
            - After editing code, build the project to verify your changes compile.
            - Do NOT commit or push unless explicitly asked. Report what you changed.
            - When multiple approaches exist, briefly explain the trade-off in chat, then \
            pick the one that matches existing project patterns.
            - SIGNING / PROVISIONING ESCALATION: If the build fails with a code-signing or \
            provisioning error (e.g., "No signing certificate", "No profiles for", "entitlements \
            that require signing with a development certificate", or team ID mismatch), you cannot \
            fix this by editing source files. STOP editing and ask the user: "The build now blocks \
            on signing/provisioning. Do you want me to (1) remove the entitlements that require a \
            development certificate for local Debug builds, or (2) leave the project as-is and stop?" \
            Do not silently disable signing or remove entitlements without explicit approval.
            """
        let modelSpecific: String
        switch flavor {
        case .large:
            modelSpecific = """

                MODEL CAPACITY: You are running on a large, capable model. You may issue up to \
                3 tool calls per turn when the work is parallel (e.g., reading several unrelated \
                files). Keep each tool call tightly scoped and reason across the results in the \
                next turn.
                """
        case .balanced:
            modelSpecific = """

                MODEL CAPACITY: You are running on a capable mid-size model. Prefer 1-2 tool \
                calls per turn. Batch reads when files are related, but avoid multi-step reasoning \
                inside a single turn — verify one step before the next.
                """
        case .small, .unknown:
            modelSpecific = """

                MODEL CAPACITY: You are running on a smaller model. Use ONE tool per turn. \
                Keep each reasoning step short. After every tool result, briefly summarize what \
                you learned, then decide the single next tool. Do NOT issue multiple tool calls \
                at once.
                """
        }
        return commonInstructions + modelSpecific
    }
}

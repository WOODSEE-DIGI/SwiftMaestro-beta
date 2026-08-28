import Foundation

/// Chat-template overlays for curated models whose stock `chat_template`
/// (tokenizer_config.json) lacks a `tools` block — without one, tool schemas
/// are silently dropped from the prompt and the model can never see the tools
/// it has (the DeepSeek-Coder-V2-Lite stock template is 459 chars of pure
/// User:/Assistant: turns despite the model being tool-call trained).
///
/// The overlay is installed as `chat_template.jinja` in the model directory —
/// swift-transformers prefers that file over the config-embedded template, so
/// tool calling starts working without touching any other model file. This
/// covers both DMG-bundled and HuggingFace-downloaded copies of the model.
enum ChatTemplateOverlays {

    /// The tools-enabled overlay for a catalog model id, if one exists.
    static func overlay(forModelID modelID: String) -> String? {
        switch modelID {
        case "local-deepseek-coder-v2-lite":
            return deepSeekCoderV2
        default:
            return nil
        }
    }

    /// DeepSeek-Coder-V2-Lite (deepseek_v2): keeps the stock User:/Assistant:
    /// turn structure the model was trained on, and adds:
    ///   - a tools preamble + schema block (native DeepSeek special-token
    ///     calling format, which the model demonstrably falls back to even
    ///     when prompted with other formats — it is the trained dialect),
    ///   - assistant `tool_calls` rendering for multi-round tool use,
    ///   - `tool` role results wrapped in the native outputs markers.
    ///
    /// In Swift source every Jinja `\n` is written `\\n` (Jinja evaluates the
    /// escape when the template renders).
    private static let deepSeekCoderV2 = """
        {% if not add_generation_prompt is defined %}{% set add_generation_prompt = false %}{% endif %}{{ bos_token }}{% if tools %}{{ 'You are a helpful assistant with tool calling capabilities. When you need to use a tool, output ONLY the tool call in exactly this format:\\n<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>FUNCTION_NAME\\n```json\\n{"arg1": "value1"}\\n```<｜tool▁call▁end｜><｜tool▁calls▁end｜>\\nStop immediately after <｜tool▁calls▁end｜> and wait for the tool result. Never invent tool outputs.\\n\\n# Tools\\n\\nYou are provided with function signatures within <tools></tools> XML tags:\\n<tools>\\n' }}{% for tool in tools %}{{ tool | tojson }}{{ '\\n' }}{% endfor %}{{ '</tools>\\n\\n' }}{% endif %}{% for message in messages %}{% if message['role'] == 'user' %}{{ 'User: ' + message['content'] + '\\n\\n' }}{% elif message['role'] == 'assistant' %}{{ 'Assistant: ' + message['content'] }}{% if message['tool_calls'] is defined and message['tool_calls'] %}{% for tc in message['tool_calls'] %}{{ '<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>' + tc['function']['name'] + '\\n```json\\n' + tc['function']['arguments'] + '\\n```<｜tool▁call▁end｜><｜tool▁calls▁end｜>' }}{% endfor %}{% endif %}{{ eos_token }}{% elif message['role'] == 'tool' %}{{ '<｜tool▁outputs▁begin｜><｜tool▁output▁begin｜>' + message['content'] + '<｜tool▁output▁end｜><｜tool▁outputs▁end｜>\\n\\n' }}{% elif message['role'] == 'system' %}{{ message['content'] + '\\n\\n' }}{% endif %}{% endfor %}{% if add_generation_prompt %}{{ 'Assistant:' }}{% endif %}
        """
}

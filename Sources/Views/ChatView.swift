import SwiftUI

struct ChatView: View {
    @Environment(MLXInferenceEngine.self) private var engine
    @Environment(ModelCatalog.self) private var catalog
    @ObservedObject var vm: ChatViewModel

    init(agent: Agent) {
        _vm = ObservedObject(wrappedValue: ChatViewModel(agent: agent))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            errorBanner
            inputBar
        }
        .navigationTitle("Chat")
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.messages.filter { $0.role != .system }) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                    loadingIndicator
                        .id("loading-indicator")
                }
                .padding(.vertical, 12)
            }
            .onChange(of: vm.messages.last?.content) {
                if let lastID = vm.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: vm.isStreaming) {
                if vm.isStreaming {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("loading-indicator", anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Shows a spinner + engine state while a model is loading or the first
    /// token is pending (the assistant bubble is still empty). A large model's
    /// first load can take a while, so this signals progress instead of a hang.
    @ViewBuilder
    private var loadingIndicator: some View {
        if vm.isStreaming, (vm.messages.last?.content.isEmpty ?? false) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(loadingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var loadingText: String {
        switch engine.state {
        case .loading(let name): return "Loading \(name)… (first load can take a while)"
        case .generating:        return "Generating…"
        case .error(let msg):    return msg
        default:                 return "Working…"
        }
    }

    private var errorBanner: some View {
        Group {
            if let errMsg = vm.errorMessage {
                HStack {
                    Text(errMsg)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("Dismiss") { vm.errorMessage = nil }
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Message...", text: $vm.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit {
                    vm.send(engine: engine, model: catalog.selectedModel)
                }

            if vm.isStreaming {
                Button { vm.cancel(engine: engine) } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                Button {
                    vm.send(engine: engine, model: catalog.selectedModel)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(vm.inputText.isEmpty ? .secondary : .blue)
                }
                .disabled(vm.inputText.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background)
    }
}

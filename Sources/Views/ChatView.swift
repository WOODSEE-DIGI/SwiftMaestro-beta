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

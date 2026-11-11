import SwiftUI

// MARK: - Editable String List
//
// Reusable editor for [String] fields (aliases, key quotes, symbols,
// source event IDs, etc.). Each row has a text field and a delete button,
// plus an add button at the bottom.

struct StoryGameEditableStringList: View {
    @Binding var items: [String]
    var placeholder: String = "Item"
    var singularName: String = "item"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(items.indices), id: \.self) { index in
                StoryGameStringRow(
                    items: $items,
                    index: index,
                    placeholder: placeholder
                )
            }

            Button {
                items.append("")
            } label: {
                Label("Add \(singularName)", systemImage: "plus.circle")
            }
        }
    }
}

private struct StoryGameStringRow: View {
    @Binding var items: [String]
    let index: Int
    var placeholder: String = "Item"

    private var textBinding: Binding<String> {
        Binding(
            get: { items[safe: index] ?? "" },
            set: { newValue in
                guard items.indices.contains(index) else { return }
                items[index] = newValue
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: textBinding)
                .textFieldStyle(.roundedBorder)

            Button {
                items.remove(at: index)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }
}



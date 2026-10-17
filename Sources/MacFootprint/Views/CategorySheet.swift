import FootprintCore
import SwiftUI

struct CategorySheet: View {
    let category: StorageCategory
    let scan: ScanResult
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var items: [CategoryItem]?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(category.color).frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title).font(.title2.weight(.semibold))
                    Text("\(ByteFormatter.string(scan.categoryTotals[category] ?? 0)) in total. Biggest items first.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
            Divider()
            content
        }
        .frame(width: 620, height: 560)
        .task {
            let roots = scan.roots
            let target = category
            items = await Task.detached(priority: .userInitiated) {
                CategoryClassifier().largestItems(in: target, roots: roots)
            }.value
        }
    }

    @ViewBuilder
    private var content: some View {
        if let items {
            if items.isEmpty {
                Text("Nothing big here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let maxBytes = Double(max(items.first?.bytes ?? 1, 1))
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            row(item, fraction: Double(item.bytes) / maxBytes)
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        } else {
            ProgressView("Looking…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ item: CategoryItem, fraction: Double) -> some View {
        Button {
            model.reveal(item.node.path)
        } label: {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.node.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.node.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(PathTools.display(item.node.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                ProportionBar(fraction: fraction, color: category.color, animated: false)
                    .frame(width: 90)
                Text(ByteFormatter.string(item.bytes))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.secondary)
                    .help("Show in Finder")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .hoverHighlight()
        }
        .buttonStyle(PressableStyle())
        .help("Show in Finder: \(item.node.path)")
    }
}

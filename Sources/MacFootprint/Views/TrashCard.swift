import FootprintCore
import SwiftUI

struct TrashCard: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirm = false
    @State private var done: TrashEmptyResult?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Palette.amber.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Your Trash holds \(ByteFormatter.string(model.trashBytes))").font(.headline).numeric()
                Text("This space is not free yet. Empty the Trash to get it back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Look Inside") { model.openTrash() }
            Button {
                confirm = true
            } label: {
                if model.isEmptyingTrash {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Emptying…")
                    }
                } else {
                    Label("Empty Trash", systemImage: "trash")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.amber)
            .disabled(model.isEmptyingTrash)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(Palette.amber.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Palette.amber.opacity(0.25)))
        .confirmationDialog("Empty the Trash?", isPresented: $confirm) {
            Button("Empty Trash (\(ByteFormatter.string(model.trashBytes)))", role: .destructive) {
                Task { done = await model.emptyTrash() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash will be deleted for good, not only what Macin moved. You can't undo this.")
        }
        .alert("Trash emptied", isPresented: Binding(get: { done != nil }, set: { if !$0 { done = nil } })) {
            Button("OK") { done = nil }
        } message: {
            if let done {
                Text(done.failedCount == 0
                     ? "Freed \(ByteFormatter.string(done.removedBytes))."
                     : "Freed \(ByteFormatter.string(done.removedBytes)). \(done.failedCount) item(s) could not be removed. Try emptying them from Finder.")
            }
        }
    }
}

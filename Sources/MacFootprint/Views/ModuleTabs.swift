import SwiftUI

protocol ModuleTab: Hashable, CaseIterable, Identifiable where AllCases: RandomAccessCollection {
    var title: String { get }
}

extension ModuleTab {
    var id: Self { self }
}

extension View {
    func moduleTabs<T: ModuleTab>(_ selection: Binding<T>) -> some View {
        toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: selection) {
                    ForEach(T.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

enum StorageTab: String, ModuleTab {
    case overview, cleanUp, history, details

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cleanUp: return "Clean Up"
        case .history: return "History"
        case .details: return "Scan Details"
        }
    }
}

struct StorageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            switch model.storageTab {
            case .overview: StorageOverview()
            case .cleanUp: CandidatesView()
            case .history: HistoryView()
            case .details: CoverageView()
            }
        }
        .moduleTabs($model.storageTab)
    }
}

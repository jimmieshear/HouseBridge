import SwiftUI
import AppKit
import HouseBridgeCore

/// Browser for everything HouseBridge can see: what each device reports, what you can do with it,
/// and a rule skeleton to paste into config.yaml.
struct DevicesView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var selection: String?

    private var filtered: [CatalogEntry] {
        guard let entries = model.catalog?.entries else { return [] }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return entries }
        return entries.filter {
            ([$0.name, $0.kind, $0.model] + $0.provides + $0.accepts + $0.details).joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                if let problems = model.catalog?.problems, !problems.isEmpty {
                    Section("Problems") {
                        ForEach(problems.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { sub in
                            Label("\(sub.rawValue.capitalized): \(problems[sub] ?? "")", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    }
                }
                ForEach(Subsystem.allCases, id: \.self) { system in
                    let items = filtered.filter { $0.system == system }
                    if !items.isEmpty {
                        Section(system.rawValue.capitalized) {
                            ForEach(items) { e in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.name)
                                    Text(e.kind).font(.caption).foregroundStyle(.secondary)
                                }
                                .tag(e.id)
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search devices and abilities")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .overlay {
                if model.catalogLoading { ProgressView("Asking your devices…") }
                else if model.catalog == nil { Text("No data yet").foregroundStyle(.secondary) }
            }
        } detail: {
            if let entry = filtered.first(where: { $0.id == selection }) {
                DeviceDetail(entry: entry)
            } else {
                Text("Select a device").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.loadCatalog() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.catalogLoading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.catalog?.text() ?? "", forType: .string)
                } label: { Label("Copy All", systemImage: "doc.on.doc") }
                    .disabled(model.catalog == nil)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
        .onAppear { if model.catalog == nil { model.loadCatalog() } }
    }
}

private struct DeviceDetail: View {
    let entry: CatalogEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.title2.bold())
                    Text(([entry.kind, entry.model].filter { !$0.isEmpty }).joined(separator: " · ")).foregroundStyle(.secondary)
                }
                section("Reports (use in when:)", entry.provides)
                section("You can (use in then:)", entry.accepts)
                section("Details", entry.details)
                if !entry.snippet.isEmpty {
                    HStack {
                        Text("Example rule").font(.headline)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.snippet, forType: .string)
                        }
                    }
                    Text(entry.snippet)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Text("Paste under “rules:” in config.yaml and replace anything in <angle brackets>.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                ForEach(lines, id: \.self) { Text("• \($0)").textSelection(.enabled) }
            }
        }
    }
}

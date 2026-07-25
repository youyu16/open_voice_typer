import SwiftData
import SwiftUI

/// History answers two questions: "where did that dictation go?" and
/// "can I use it again?" — day grouping, search over polished AND raw text,
/// source/template filters, and a detail sheet that keeps raw one tap away.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptRecord.createdAt, order: .reverse)
    private var records: [TranscriptRecord]

    @State private var searchText = ""
    @State private var sourceFilter: SourceFilter = .all
    @State private var templateFilter: String?
    @State private var selectedRecord: TranscriptRecord?

    enum SourceFilter: String, CaseIterable {
        case all = "All"
        case keyboard = "Keyboard"
        case inApp = "In-app"
    }

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    ContentUnavailableView(
                        "No dictations yet",
                        systemImage: "clock",
                        description: Text("Finished dictations appear here.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search dictations")
            .sheet(item: $selectedRecord) { record in
                HistoryDetailSheet(record: record)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    private var list: some View {
        List {
            Section {
                filterChips
                    .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            ForEach(groupedRecords, id: \.day) { group in
                Section(header: Text(group.day, format: .dateTime.weekday(.wide).month().day())) {
                    ForEach(group.records) { record in
                        row(for: record)
                    }
                }
            }
        }
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SourceFilter.allCases, id: \.self) { filter in
                    chip(filter.rawValue, isOn: sourceFilter == filter) {
                        sourceFilter = filter
                    }
                }
                Menu {
                    Button("Any template") { templateFilter = nil }
                    ForEach(SharedCatalog.loadStyles()) { style in
                        Button(style.name) { templateFilter = style.id }
                    }
                } label: {
                    chipLabel(
                        templateFilter.flatMap { SharedCatalog.style(id: $0)?.name } ?? "Template",
                        isOn: templateFilter != nil,
                        trailingIcon: "chevron.up.chevron.down"
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(label, isOn: isOn) }
            .buttonStyle(.plain)
    }

    private func chipLabel(_ label: String, isOn: Bool, trailingIcon: String? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
            if let trailingIcon {
                Image(systemName: trailingIcon).font(.caption2)
            }
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            isOn ? AnyShapeStyle(LinearGradient.appAccentFill) : AnyShapeStyle(Color(.tertiarySystemFill)),
            in: Capsule()
        )
        .foregroundStyle(isOn ? .white : .primary)
        .shadow(color: isOn ? Color.appAccent.opacity(0.3) : .clear, radius: 5, y: 2)
    }

    private func row(for record: TranscriptRecord) -> some View {
        Button {
            selectedRecord = record
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.polishedText)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    TemplateTag(name: record.styleName)
                    if record.source == TranscriptRecord.Source.keyboard.rawValue {
                        Label("keyboard", systemImage: "keyboard")
                            .labelStyle(.iconOnly)
                    }
                    Text(record.createdAt, format: .dateTime.hour().minute())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                UIPasteboard.general.string = record.polishedText
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .tint(.appAccent)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                modelContext.delete(record)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: Filtering & grouping

    private var filteredRecords: [TranscriptRecord] {
        records.filter { record in
            switch sourceFilter {
            case .all: break
            case .keyboard:
                guard record.source == TranscriptRecord.Source.keyboard.rawValue else { return false }
            case .inApp:
                guard record.source == TranscriptRecord.Source.app.rawValue else { return false }
            }
            if let templateFilter, record.styleID != templateFilter { return false }
            if !searchText.isEmpty {
                // People remember what they meant, not what the model wrote —
                // match raw and polished alike.
                return record.polishedText.localizedCaseInsensitiveContains(searchText)
                    || record.rawText.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    private var groupedRecords: [(day: Date, records: [TranscriptRecord])] {
        Dictionary(grouping: filteredRecords) {
            Calendar.current.startOfDay(for: $0.createdAt)
        }
        .sorted { $0.key > $1.key }
        .map { (day: $0.key, records: $0.value) }
    }
}

struct TemplateTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.appAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(Color.appAccent)
    }
}

/// Polished/Raw toggle, cost-debugging metadata, Copy / Re-polish / Delete.
private struct HistoryDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let record: TranscriptRecord

    @State private var showRaw = false
    @State private var isRepolishing = false
    @State private var repolishError: String?
    /// Read once when the sheet opens; Settings lives in App Group defaults.
    private let showsTimings = SettingsStore.load().showsTimings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Version", selection: $showRaw) {
                Text("Polished").tag(false)
                Text("Raw").tag(true)
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(showRaw ? record.rawText : record.polishedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                TemplateTag(name: record.styleName)
                if !record.engineName.isEmpty {
                    Text(record.engineName)
                }
                if record.audioSeconds > 0 {
                    Text(Duration.seconds(record.audioSeconds), format: .time(pattern: .minuteSecond))
                        .monospacedDigit()
                }
                Text(record.createdAt, format: .dateTime.hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if showsTimings, let latency = record.latency {
                timingBreakdown(latency)
            }

            if let repolishError {
                Text(repolishError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button {
                    UIPasteboard.general.string = showRaw ? record.rawText : record.polishedText
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Menu {
                    ForEach(SharedCatalog.loadStyles().filter { $0.id != Style.raw.id }) { style in
                        Button(style.name) { repolish(with: style) }
                    }
                } label: {
                    HStack {
                        if isRepolishing {
                            ProgressView().controlSize(.small)
                        }
                        Label("Re-polish", systemImage: "wand.and.stars")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isRepolishing)
            }

            Button("Delete", role: .destructive) {
                modelContext.delete(record)
                dismiss()
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
    }

    /// Where the wait actually went, shown only when the user has asked for it
    /// in Settings. Stages that didn't run are omitted, and the remainder is
    /// labelled rather than hidden so the parts add up to the total.
    private func timingBreakdown(_ latency: TranscriptRecord.Latency) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            timingRow("Total", milliseconds: latency.total, emphasized: true)
            ForEach(latency.stages, id: \.name) { stage in
                timingRow(stage.name, milliseconds: stage.milliseconds)
            }
            if latency.otherMilliseconds > 0 {
                timingRow("Other", milliseconds: latency.otherMilliseconds)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.keyCap, in: RoundedRectangle(cornerRadius: 10))
    }

    private func timingRow(_ name: String, milliseconds: Int, emphasized: Bool = false) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(TranscriptRecord.Latency.format(milliseconds: milliseconds))
                .monospacedDigit()
        }
        .fontWeight(emphasized ? .semibold : .regular)
        .foregroundStyle(emphasized ? .primary : .secondary)
    }

    /// Reruns the stored raw transcript through another template — no
    /// re-speaking. Lands as a new history entry.
    private func repolish(with style: Style) {
        isRepolishing = true
        repolishError = nil
        let pipeline = DictationPipeline(settings: SettingsStore.load())
        let rawText = record.rawText
        let source = record.source
        let audioSeconds = record.audioSeconds

        Task {
            defer { isRepolishing = false }
            do {
                // A re-polish is one hop, so the total *is* the polish time —
                // there is no speech stage to attribute anything to.
                let start = ContinuousClock.now
                let polished = try await pipeline.polishOnly(rawText: rawText, style: style)
                let elapsed = (ContinuousClock.now - start).milliseconds
                modelContext.insert(TranscriptRecord(
                    rawText: rawText,
                    polishedText: polished,
                    styleID: style.id,
                    source: TranscriptRecord.Source(rawValue: source) ?? .app,
                    engineName: pipeline.polishEngineName,
                    audioSeconds: audioSeconds,
                    totalMilliseconds: elapsed,
                    polishMilliseconds: elapsed
                ))
                dismiss()
            } catch {
                repolishError = error.localizedDescription
            }
        }
    }
}

#Preview {
    HistoryView()
        .modelContainer(for: TranscriptRecord.self, inMemory: true)
}

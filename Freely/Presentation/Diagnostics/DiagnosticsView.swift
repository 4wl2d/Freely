import AppKit
import FreelyCore
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Bindable var model: ApplicationModel
    @State private var snapshot = FreelyLog.recorder.snapshot()
    @State private var report: DiagnosticReport?
    @State private var search = ""
    @State private var minimumLevel = DiagnosticLevel.debug
    @State private var category = ""
    @State private var live = true
    @State private var selection: UInt64?
    @State private var selectedTab = 0
    @State private var notice = ""
    @State private var savePanel: NSSavePanel?
    @State private var exportTask: Task<Void, Never>?

    private var events: [DiagnosticEvent] {
        snapshot.events.reversed().filter { $0.matches(search: search, minimumLevel: minimumLevel, category: category) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Page", selection: $selectedTab) {
                Text("Overview").tag(0); Text("Events").tag(1); Text("Timings").tag(2); Text("Environment").tag(3)
            }.pickerStyle(.segmented)
            switch selectedTab {
            case 0: DiagnosticsOverview(model: model)
            case 1: eventTimeline
            case 2: timingView
            default: environmentView
            }
            HStack {
                Text("\(snapshot.events.count) / \(snapshot.capacity) events · \(snapshot.evicted) evicted · \(snapshot.suppressedDebug) debug events omitted")
                Spacer()
                Text(notice).lineLimit(1)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .task {
            refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                if live && model.section == .diagnostics && model.overlayVisible { refresh() }
            }
        }
        .onDisappear { savePanel?.cancel(nil); savePanel = nil }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Diagnostics").font(.headline)
                    Text("Run \(snapshot.runID.uuidString.prefix(8)) · errors: \(snapshot.counts["error", default: 0]) · warnings: \(snapshot.counts["warning", default: 0])")
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.expanded ? "Compact" : "Expand") { model.toggleExpanded() }
                Button("Copy report", systemImage: "doc.on.doc") { copyReport() }
                Button("Export JSON…", systemImage: "square.and.arrow.up") { exportReport() }
                    .disabled(savePanel != nil || exportTask != nil)
            }
            Text("States, timings and classified errors only. No meeting text, images or credentials. Reports include all retained events and the state at the last refresh, regardless of filters.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var eventTimeline: some View {
        let visibleEvents = events
        return VStack(spacing: 10) {
            HStack {
                TextField("Search event, field, session or request ID", text: $search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search diagnostic events")
                PanelPicker("Level", selection: $minimumLevel, options: [("All", .debug), ("Info+", .info), ("Warnings+", .warning), ("Errors", .error)]).frame(width: 125)
                PanelPicker("Category", selection: $category, options: [("All", "")] + Array(Set(DiagnosticName.allCases.map(\.category))).sorted().map { ($0, $0) }).frame(width: 160)

            }
            HStack {
                Button(live ? "Pause events" : "Resume events", systemImage: live ? "pause" : "play") { live.toggle(); if live && model.section == .diagnostics && model.overlayVisible { refresh() } }
                Toggle("Debug detail", isOn: Binding(get: { snapshot.verbose }, set: { FreelyLog.recorder.setVerbose($0); refresh() }))
                    .toggleStyle(.checkbox).help("Records per-decode and final transcript metadata until turned off or the app exits. Never records text.")
                Button("Add marker", systemImage: "flag") { FreelyLog.record(.debugMarker); refresh() }
                Spacer()
                Text("Matches: \(visibleEvents.count) · newest first").font(.caption).foregroundStyle(.secondary)
                Button("Clear events") { FreelyLog.recorder.clear(); selection = nil; refresh(); notice = "Memory cleared; existing exports and macOS logs remain." }
            }.controlSize(.small)
            Table(visibleEvents, selection: $selection) {
                TableColumn("Time") { event in Text(event.date, format: .dateTime.hour().minute().second()).monospacedDigit() }.width(75)
                TableColumn("Level") { event in Text(event.level.rawValue.uppercased()).font(.caption.bold()).foregroundStyle(color(event.level)) }.width(65)
                TableColumn("Event", value: \.name.rawValue).width(min: 155, ideal: 210)
                TableColumn("Source") { event in Text(event.scope.source?.label ?? "—") }.width(100)
                TableColumn("Details", value: \.details)
            }
            .font(.system(size: 11, design: .monospaced))
            .overlay {
                if visibleEvents.isEmpty { ContentUnavailableView("No matching events", systemImage: "line.3.horizontal.decrease.circle", description: Text("Adjust the filters or reproduce the action you want to inspect.")) }
            }
            if let selected = visibleEvents.first(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("#\(selected.id)  \(selected.name.rawValue)").bold()
                        Spacer()
                        Button("Copy event") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("#\(selected.id) \(selected.name.rawValue)\n\(selected.details)", forType: .string)
                        }
                    }
                    Text("Session: \(selected.scope.session?.uuidString ?? "—")    Request: \(selected.scope.request?.uuidString ?? "—")")
                    Text(selected.details.isEmpty ? "No additional fields" : selected.details)
                }
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.top, 12)
    }
    private var timingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent timing distributions").font(.headline)
            Text("Each row retains the latest 256 valid samples across this app run. Count includes all samples since Clear. Timings are measured even with debug detail off; percentiles are not service guarantees.")
                .font(.caption).foregroundStyle(.secondary)
            Table(snapshot.timings) {
                TableColumn("Measurement", value: \.name.rawValue)
                TableColumn("Count") { Text(String($0.count)) }.width(65)
                TableColumn("Retained") { Text(String($0.retainedSamples)) }.width(65)
                TableColumn("p50") { Text(duration($0.p50)) }.width(85)
                TableColumn("p95") { Text(duration($0.p95)) }.width(85)
                TableColumn("Max") { Text(duration($0.maximum)) }.width(85)
            }.overlay {
                if snapshot.timings.isEmpty { ContentUnavailableView("No timings yet", systemImage: "stopwatch", description: Text("Start a session or request an answer to collect measurements.")) }
            }
        }.padding(12)
    }
    private var environmentView: some View {
        ScrollView { VStack(alignment: .leading, spacing: 24) {
            SettingsSection("Build & runtime") {
                ForEach((report?.environment ?? [:]).keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: report?.environment[key] ?? "—").textSelection(.enabled)
                }
                LabeledContent("Run ID", value: snapshot.runID.uuidString).textSelection(.enabled)
            }
            SettingsSection("Current state · updated every 0.5 seconds while live") {
                ForEach((report?.state ?? [:]).keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: report?.state[key] ?? "—").textSelection(.enabled)
                }
            }
            SettingsSection("Capture boundaries") {
                Text("Microphone permission and screen-pixel permission are separate from successfully starting system audio. A configured AI connection does not prove inference access. Resident memory includes the warm local model cache. Owned tasks cover session coordinator work, not framework internals.")
                Text("Events are held in memory until cleared or the process exits. macOS manages unified-log retention separately. For a crash or hang, use script/diagnose.sh and the debugging guide.")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16) }
    }
    private func refresh() {
        snapshot = FreelyLog.recorder.snapshot()
        report = DiagnosticReport(recording: snapshot, state: model.diagnosticState)
    }
    private func copyReport() {
        do {
            guard let report else { return }
            let data = try report.json()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
            notice = "Report copied."
        } catch { notice = "Could not encode the diagnostic report." }
    }
    private func exportReport() {
        guard savePanel == nil, exportTask == nil, let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Freely-diagnostics-\(snapshot.runID.uuidString.prefix(8)).json"
        panel.message = "Exports the state at the last refresh and all retained events. No meeting content or credentials are included."
        savePanel = panel
        model.dialogs.present(panel) { response in
            savePanel = nil
            guard response == .OK, let url = panel.url else { return }
            // The immutable report is captured before opening the sheet. Encoding and writing stay off MainActor.
            exportTask = Task {
                do {
                    try await Task.detached(priority: .utility) {
                        try report.json().write(to: url, options: .atomic)
                    }.value
                    notice = "Diagnostic report exported."
                } catch { notice = "Export failed. Choose a writable location." }
                exportTask = nil
            }
        }
    }
    private func duration(_ value: Double?) -> String { value.map { String(format: "%.3f s", $0) } ?? "—" }
    private func color(_ level: DiagnosticLevel) -> Color {
        switch level { case .debug: .secondary; case .info: .primary; case .warning: .orange; case .error: .red }
    }
}

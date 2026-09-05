import DarkbloomTelemetry
import SwiftUI

struct LogsQuery {
    var severity: LogSeverity? = nil
    var source: LogSource? = nil
    var text = ""

    func apply(_ events: [LogEvent]) -> [LogEvent] {
        let search = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return events.filter { event in
            (severity == nil || event.severity == severity)
                && (source == nil || event.source == source)
                && (search.isEmpty || event.message.localizedCaseInsensitiveContains(search)
                    || event.category.localizedCaseInsensitiveContains(search))
        }
    }
}

struct LogsView: View {
    let feed: SourceAvailability<EventFeed>
    @State private var query = LogsQuery()
    @State private var exportPreview: LogExportSnapshot?
    @State private var exportFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent logs").font(.title2.bold())
                Spacer()
                Button("Preview export…") { prepareExport() }
                    .disabled(query.apply(feed.value?.events ?? []).isEmpty)
            }
            Text("Up to 100 events and 128 KiB of text. Known sensitive fields are withheld; review before sharing. Oversized events are omitted. No commands or links are executed.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Search message or category", text: $query.text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search logs")
            HStack {
                Picker("Severity", selection: $query.severity) {
                    Text("All").tag(nil as LogSeverity?)
                    ForEach([LogSeverity.info, .notice, .warning, .error], id: \.rawValue) {
                        Text($0.rawValue.capitalized).tag(Optional($0))
                    }
                }
                Picker("Source", selection: $query.source) {
                    Text("All").tag(nil as LogSource?)
                    Text("Legacy").tag(Optional(LogSource.legacy))
                    Text("Unified").tag(Optional(LogSource.unified))
                }
            }
            if case .stale(_, _, let reason) = feed {
                Text("Stale events — \(reason)").font(.callout).foregroundStyle(.orange)
            }
            if exportFailed {
                Text("Could not prepare an export from this snapshot.")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let message = feed.eventEmptyMessage {
                Text(message).foregroundStyle(.secondary)
            } else {
                let events = query.apply(feed.value?.events ?? [])
                if events.isEmpty {
                    Text("No events match these filters.").foregroundStyle(.secondary)
                }
                List {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        EventRow(event: event).padding(.vertical, 6)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $exportPreview) { snapshot in
            LogExportPreviewView(snapshot: snapshot)
        }
    }

    private func prepareExport() {
        exportFailed = false
        let capturedAt: Date
        let stale: Bool
        switch feed {
        case .available(_, let date): capturedAt = date; stale = false
        case .stale(_, let date, _): capturedAt = date; stale = true
        case .unavailable: return
        }
        do {
            exportPreview = try LogExportSnapshot.make(events: query.apply(feed.value?.events ?? []),
                sourceCapturedAt: capturedAt, sourceIsStale: stale, createdAt: Date())
        } catch {
            exportFailed = true
        }
    }
}

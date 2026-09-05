import DarkbloomTelemetry
import SwiftUI
import UniformTypeIdentifiers

struct LogExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(snapshot: LogExportSnapshot) { data = snapshot.data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              data.count <= LogExportSnapshot.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LogExportPreviewView: View {
    let snapshot: LogExportSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var reviewed = false
    @State private var showsSave = false
    @State private var resultMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review log export").font(.title2.bold())
            Text("\(snapshot.eventCount) events · \(snapshot.omittedCount) omitted · \(snapshot.data.count) bytes")
                .foregroundStyle(.secondary)
            Text("This is a frozen snapshot of your filtered events. Known sensitive fields are withheld, but unmarked private text may remain. Review before saving or sharing. No file has been saved by opening this preview.")
                .font(.callout)
            ScrollView {
                Text(verbatim: snapshot.previewText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Toggle("I reviewed this snapshot for private information", isOn: $reviewed)
                .toggleStyle(.checkbox)
            if let resultMessage {
                Text(resultMessage).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save JSON…") { showsSave = true }
                    .disabled(!reviewed)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 700, minHeight: 550, idealHeight: 650)
        .fileExporter(isPresented: $showsSave, document: LogExportDocument(snapshot: snapshot),
                      contentType: .json, defaultFilename: "darkbloom-logs") { result in
            switch result {
            case .success: resultMessage = "The reviewed snapshot was saved."
            case .failure: resultMessage = "The snapshot could not be saved. You can retry or close this preview."
            }
        }
    }
}

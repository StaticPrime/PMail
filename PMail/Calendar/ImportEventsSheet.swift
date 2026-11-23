import AppKit
import PMailKit
import SwiftUI
import UniformTypeIdentifiers

/// Events read from a file, waiting to be imported into one of the account's calendars.
struct ImportedEvents: Identifiable {
    let id = UUID()
    let fileName: String
    let events: [CalendarEvent]
    let skipped: Int

    /// Asks for an iCalendar, vCalendar or CSV file and reads its events; nil when none was chosen. A file with no
    /// events in it says so.
    @MainActor
    static func choose(app: AppModel) -> ImportedEvents? {
        let panel = NSOpenPanel()
        panel.title = "Import Events"
        panel.prompt = "Import"
        panel.message = "Choose an iCalendar (.ics), vCalendar (.vcs) or CSV file."
        panel.allowedContentTypes = CalendarImport.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let result = try CalendarImport.events(from: try Data(contentsOf: url), fileExtension: url.pathExtension)
            guard !result.events.isEmpty else {
                app.show("There are no events in “\(url.lastPathComponent)” that PMail can read.")
                return nil
            }
            return ImportedEvents(fileName: url.lastPathComponent, events: result.events, skipped: result.skipped)
        } catch {
            app.report(error, doing: "Reading “\(url.lastPathComponent)”")
            return nil
        }
    }
}

/// Importing a file's events: how many there are, and the calendar they go to.
struct ImportEventsSheet: View {
    let app: AppModel
    let model: CalendarViewModel
    let file: ImportedEvents
    @State private var calendarID: String = ""
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let targets = model.importTargets
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Events").font(.pm(20)).foregroundStyle(Theme.textPrimary)
            Text(summary).font(.pm(12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Picker("Add them to", selection: $calendarID) {
                ForEach(targets) { calendar in Text(calendar.name).tag(calendar.id) }
            }
            .disabled(isWorking)
            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                FilledPillButton(title: isWorking ? "Importing…" : "Import", isDisabled: isWorking || calendarID.isEmpty) { importEvents() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .font(.pm(13))
        .padding(24)
        .frame(width: 460)
        .background(Theme.surface)
        .onAppear { if calendarID.isEmpty { calendarID = (targets.first(where: \.isPrimary) ?? targets.first)?.id ?? "" } }
    }

    private var summary: String {
        let count = file.events.count == 1 ? "One event" : "\(file.events.count) events"
        let skipped = file.skipped == 0 ? "" : " (\(file.skipped) more couldn’t be read)"
        return "\(count) from “\(file.fileName)”\(skipped). They come without guests, so no one is sent an invitation."
    }

    private func importEvents() {
        isWorking = true
        Task {
            let done = await model.importEvents(file.events, into: calendarID)
            let name = model.calendarInfo(calendarID)?.name ?? "the calendar"
            let failed = done.failed == 0 ? "" : " \(done.failed) couldn’t be added."
            app.show((done.added == 1 ? "Imported one event into “\(name)”." : "Imported \(done.added) events into “\(name)”.") + failed)
            dismiss()
        }
    }
}

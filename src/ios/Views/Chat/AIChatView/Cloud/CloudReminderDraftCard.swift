import EventKit
import SwiftUI

struct CloudReminderDraftCard: View {
    let card: CloudCards.Card
    @State private var isEditing = false
    @State private var saved = false

    var body: some View {
        Button {
            isEditing = true
        } label: {
            Label(saved ? "已保存到提醒事项" : (card.payload["title"] as? String ?? ""),
                  systemImage: saved ? "checkmark.circle" : "checklist")
        }
        .buttonStyle(.bordered)
        .disabled(saved)
        .accessibilityHint("预览并保存到苹果提醒事项")
        .sheet(isPresented: $isEditing) {
            NavigationView {
                CloudReminderDraftEditor(
                    title: card.payload["title"] as? String ?? "",
                    notes: card.payload["notes"] as? String ?? "",
                    due: card.payload["due"] as? String ?? "",
                    onSave: { saved = true }
                )
            }
        }
    }
}

private struct CloudReminderDraftEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let onSave: () -> Void
    @State private var title: String
    @State private var notes: String
    @State private var hasDueDate: Bool
    @State private var includesTime: Bool
    @State private var dueDate: Date
    @State private var store = EKEventStore()
    @State private var calendars: [EKCalendar] = []
    @State private var calendarID = ""
    @State private var isSaving = false
    @State private var errorText: String?

    init(title: String, notes: String, due: String, onSave: @escaping () -> Void) {
        self.onSave = onSave
        _title = State(initialValue: title)
        _notes = State(initialValue: notes)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = due.count == 10 ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        let date = formatter.date(from: due)
        _hasDueDate = State(initialValue: date != nil)
        _includesTime = State(initialValue: date != nil && due.count > 10)
        _dueDate = State(initialValue: date ?? Date())
    }

    var body: some View {
        Form {
            TextField("标题", text: $title)
            TextField("备注", text: $notes, axis: .vertical)
            Toggle("截止日期", isOn: $hasDueDate)
            if hasDueDate {
                Toggle("指定时间", isOn: $includesTime)
                DatePicker("到期", selection: $dueDate, displayedComponents: includesTime ? [.date, .hourAndMinute] : [.date])
            }
            if !calendars.isEmpty {
                Picker("列表", selection: $calendarID) {
                    ForEach(calendars, id: \.calendarIdentifier) { calendar in
                        Text(calendar.title).tag(calendar.calendarIdentifier)
                    }
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .navigationTitle("待办草稿")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(calendars.isEmpty ? "选择列表" : "保存") { Task { await saveOrChooseCalendar() } }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear { loadCalendars() }
    }

    @MainActor
    private func loadCalendars() {
        calendars = store.calendars(for: .reminder).filter(\.allowsContentModifications)
        if !calendars.contains(where: { $0.calendarIdentifier == calendarID }) {
            calendarID = store.defaultCalendarForNewReminders()?.calendarIdentifier ?? ""
            if !calendars.contains(where: { $0.calendarIdentifier == calendarID }) {
                calendarID = calendars.first?.calendarIdentifier ?? ""
            }
        }
    }

    @MainActor
    private func saveOrChooseCalendar() async {
        guard !isSaving else { return }
        isSaving = true
        errorText = nil
        defer { isSaving = false }
        do {
            if calendars.isEmpty {
                let granted: Bool
                if #available(iOS 17, *) {
                    granted = try await store.requestFullAccessToReminders()
                } else {
                    granted = try await store.requestAccess(to: .reminder)
                }
                guard granted else {
                    errorText = "请在系统设置中允许 Minis 访问提醒事项。"
                    return
                }
                loadCalendars()
                if calendars.isEmpty { errorText = "没有可写入的提醒事项列表。" }
                return
            }
            guard let calendar = calendars.first(where: { $0.calendarIdentifier == calendarID }) else { return }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            reminder.notes = notes.isEmpty ? nil : notes
            reminder.calendar = calendar
            if hasDueDate {
                let parts: Set<Calendar.Component> = includesTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
                var date = Calendar.current.dateComponents(parts, from: dueDate)
                if includesTime { date.timeZone = .current }
                reminder.dueDateComponents = date
            }
            try store.save(reminder, commit: true)
            onSave()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

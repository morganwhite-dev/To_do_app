// QuickTodo – a polished macOS SwiftUI to‑do app with on‑device storage (SwiftData)
// and reliable local notifications using UserNotifications.
//
// ✅ Privacy-first: no networking, all data stays local.
// ✅ Quick‑entry parser: "Pay rent tomorrow 9am #Personal" → task + due date + category.
// ✅ Works on macOS 14+ (Sonoma) with Xcode 15+. Uses SwiftData (@Model).
// ✅ Desktop notifications with snooze & mark‑done actions.
// ✅ Modern dark UI, grid cards, toolbar, categories, menu bar quick‑add.
//
// ─────────────────────────────────────────────────────────────────────────────
// HOW TO RUN
// 1) In Xcode: File → New → Project → App (macOS) → Product Name: QuickTodo →
//    Interface: SwiftUI, Language: Swift. Minimum: macOS 14.0 (or newer).
// 2) Replace the default App & ContentView with this single file.
// 3) Build & Run. Allow notifications on first launch.
//
// ─────────────────────────────────────────────────────────────────────────────
// MARK: Imports

import SwiftUI
import AppKit
import SwiftData
import UserNotifications
import Combine

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Theme & Categories

enum Theme {
    static let accent = Color(hue: 0.58, saturation: 0.60, brightness: 0.78) // Indigo
    static let bg = LinearGradient(
        colors: [
            Color(hue: 0.62, saturation: 0.22, brightness: 0.16), // deep slate
            Color(hue: 0.62, saturation: 0.20, brightness: 0.12)  // deeper slate
        ], startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let cardFill = Color.white.opacity(0.08)
    static let cardBorder = Color.white.opacity(0.12)
    static let critical = Color(hue: 0.0, saturation: 0.78, brightness: 0.90)
    static let dueSoon = Color(hue: 0.12, saturation: 0.80, brightness: 0.92)
}

enum Categories {
    // Fallback stable color (used when a category has no saved custom color)
    static func fallbackColor(for name: String) -> Color {
        let hash = abs(name.lowercased().hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.70, brightness: 0.90)
    }

    // Resolve a color for a CategoryItem (custom if set, otherwise stable fallback)
    static func color(for category: CategoryItem) -> Color {
        if let hex = category.colorHex, let c = Color(hex: hex) {
            return c
        }
        return fallbackColor(for: category.name)
    }

    // Resolve a color by name, given the categories list (custom if exists, otherwise fallback)
    static func color(for name: String, in categories: [CategoryItem]) -> Color {
        if let cat = categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return color(for: cat)
        }
        return fallbackColor(for: name)
    }
}



// ─────────────────────────────────────────────────────────────────────────────
// MARK: Color <-> Hex Helpers (for user-picked subject colors)

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }

        let r, g, b, a: Double
        if s.count == 6 {
            r = Double((value & 0xFF0000) >> 16) / 255.0
            g = Double((value & 0x00FF00) >> 8) / 255.0
            b = Double(value & 0x0000FF) / 255.0
            a = 1.0
        } else {
            r = Double((value & 0xFF000000) >> 24) / 255.0
            g = Double((value & 0x00FF0000) >> 16) / 255.0
            b = Double((value & 0x0000FF00) >> 8) / 255.0
            a = Double(value & 0x000000FF) / 255.0
        }

        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    func toHex(includeAlpha: Bool = false) -> String? {
        let ns = NSColor(self).usingColorSpace(.sRGB)
        guard let c = ns else { return nil }

        let r = Int(round(c.redComponent * 255))
        let g = Int(round(c.greenComponent * 255))
        let b = Int(round(c.blueComponent * 255))
        let a = Int(round(c.alphaComponent * 255))

        if includeAlpha {
            return String(format: "#%02X%02X%02X%02X", r, g, b, a)
        } else {
            return String(format: "#%02X%02X%02X", r, g, b)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Model (SwiftData)

@Model final class TaskItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var title: String
    var notes: String
    var dueDate: Date?
    var isCompleted: Bool
    var createdAt: Date
    var completedAt: Date?
    var category: String // NEW

    init(id: UUID = UUID(), title: String, notes: String = "", dueDate: Date? = nil, isCompleted: Bool = false, createdAt: Date = .now, completedAt: Date? = nil, category: String = "Inbox") {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.category = category
    }
}

@Model final class CategoryItem: Identifiable {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    // Optional user-picked color. If nil, we fall back to a stable generated color.
    var colorHex: String?

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.colorHex = colorHex
    }
}


// Convenience query helpers
extension TaskItem {
    static func upcomingPredicate(includeDone: Bool = false) -> Predicate<TaskItem> {
        if includeDone { return #Predicate<TaskItem> { _ in true } }
        return #Predicate<TaskItem> { !$0.isCompleted }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Notifications

final class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    private override init() { super.init() }

    enum CategoryID { static let taskDue = "TASK_DUE_CATEGORY" }
    enum ActionID { static let markDone = "MARK_DONE"; static let snooze5 = "SNOOZE_5" }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let mark = UNNotificationAction(identifier: ActionID.markDone, title: "Mark Done", options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: ActionID.snooze5, title: "Snooze 5 min", options: [])
        let category = UNNotificationCategory(identifier: CategoryID.taskDue, actions: [mark, snooze], intentIdentifiers: [])
        center.setNotificationCategories([category])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error { print("[Notif] auth error: \(error)") }
            print("[Notif] granted=\(granted)")
        }
    }

    func schedule(for task: TaskItem) {
        func schedule(for task: TaskItem) {
            guard let due = task.dueDate, !task.isCompleted else { return }
            guard due > Date().addingTimeInterval(2) else { return }

            // Main due notification
            let content = UNMutableNotificationContent()
            content.title = task.title
            if !task.notes.isEmpty { content.body = task.notes }
            content.sound = .default
            content.categoryIdentifier = CategoryID.taskDue
            content.userInfo = ["taskID": task.id.uuidString]

            let mainTrig = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due),
                repeats: false
            )
            let mainID = task.id.uuidString
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: mainID, content: content, trigger: mainTrig)
            )

            // 🔔 10-minute pre-alert
            let pre = due.addingTimeInterval(-600) // -10 min
            if pre > Date().addingTimeInterval(2) {
                let preContent = UNMutableNotificationContent()
                preContent.title = "Upcoming: \(task.title)"
                preContent.body = "Due in 10 minutes."
                preContent.sound = .default
                preContent.categoryIdentifier = CategoryID.taskDue
                preContent.userInfo = ["taskID": task.id.uuidString]

                let preTrig = UNCalendarNotificationTrigger(
                    dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: pre),
                    repeats: false
                )
                let preID = mainID + "-pre"
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: preID, content: preContent, trigger: preTrig)
                )
            }
        }

    }

    func cancel(for task: TaskItem) {
        let ids = [task.id.uuidString, task.id.uuidString + "-pre"]
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }


    // Actions
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let idStr = response.notification.request.content.userInfo["taskID"] as? String, let uuid = UUID(uuidString: idStr) else { return }
        switch response.actionIdentifier {
        case ActionID.markDone: await markTaskDone(uuid: uuid)
        case ActionID.snooze5:  await snoozeTask(uuid: uuid, minutes: 5)
        default: break
        }
    }

    private func markTaskDone(uuid: UUID) async {
        await MainActor.run {
            if let model = SwiftDataBridge.shared.modelContainer?.mainContext,
               let task = try? model.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == uuid })).first {
                task.isCompleted = true
                task.completedAt = .now
                self.cancel(for: task)
                try? model.save()
            }
        }
    }

    private func snoozeTask(uuid: UUID, minutes: Int) async {
        await MainActor.run {
            if let model = SwiftDataBridge.shared.modelContainer?.mainContext,
               let task = try? model.fetch(FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == uuid })).first {
                task.dueDate = Date().addingTimeInterval(Double(minutes) * 60)
                self.schedule(for: task)
                try? model.save()
            }
        }
    }
}

final class SwiftDataBridge { static let shared = SwiftDataBridge(); var modelContainer: ModelContainer? }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Date Parsing (quick entry with #category)

enum QuickDateParser {
    struct Result { let title: String; let date: Date?; let category: String? }

    static func parse(_ raw: String, now: Date = .now) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Result(title: "", date: nil, category: nil)
        }

        // 1) Extract optional #category first
        var working = trimmed
        var foundCategory: String? = nil

        // Supports:
        //   1) #Senior Seminar   (spaces allowed, but tag must be at the END)
        //   2) #["Senior Seminar"] or #["Senior Seminar"]? (we'll do #[Senior Seminar])
        //   3) #"Senior Seminar" (quoted, at the END)
        //
        // Recommendation: put the tag at the end of the quick-add line for predictable parsing.
        let tagPatterns: [String] = [
            #"(?i)\s#\[(.+?)\]\s*$"#,     // #[Senior Seminar]
            #"(?i)\s#\"(.+?)\"\s*$"#,  // #"Senior Seminar"
            #"(?i)\s#([a-z0-9_-]+(?:\s+[a-z0-9_-]+)*)\s*$"# // #Senior Seminar
        ]

        for p in tagPatterns {
            guard let r = try? NSRegularExpression(pattern: p) else { continue }
            let ns = working as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = r.firstMatch(in: working, range: range),
               m.numberOfRanges >= 2 {
                let tag = ns.substring(with: m.range(at: 1))
                working = ns.replacingCharacters(in: m.range, with: "")
                foundCategory = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // 2) Try explicit month/day first (“december 7th”, “decemeber 7th”, etc.)
        if let manual = parseMonthDay(in: working, now: now) {
            return Result(
                title: manual.title.isEmpty ? working : manual.title,
                date: manual.date,
                category: foundCategory
            )
        }

        // 3) Fallbacks: today / tomorrow / weekday + optional time
        let lower = working.lowercased()
        var target: Date? = nil
        let cal = Calendar.current

        if lower.contains("tomorrow") {
            target = cal.date(byAdding: .day, value: 1, to: now)
        } else if lower.contains("today") {
            target = now
        } else if let weekdayIndex = weekday(from: lower) {
            target = next(weekdayIndex, now: now)
        }

        var finalDate = target
        if let time = extractTime(from: lower) {
            let base = target ?? now
            finalDate = cal.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: base)
        }

        return Result(
            title: working,
            date: finalDate,
            category: foundCategory
        )
    }

    // MARK: - Explicit month/day parsing

    /// Matches things like:
    /// "december 7", "december 7th", "december 7 2025", and typo "decemeber"
    private static func parseMonthDay(in text: String, now: Date) -> (title: String, date: Date)? {
        let pattern = #"(?i)\b(january|february|march|april|may|june|july|august|september|october|november|december|decemeber)\s+(\d{1,2})(st|nd|rd|th)?(,?\s+(\d{4}))?\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }

        let monthName = ns.substring(with: match.range(at: 1))
        let dayString = ns.substring(with: match.range(at: 2))
        let yearString: String? = match.range(at: 5).location != NSNotFound
            ? ns.substring(with: match.range(at: 5))
            : nil

        let months: [String: Int] = [
            "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
            "july": 7, "august": 8, "september": 9, "october": 10, "november": 11,
            "december": 12, "decemeber": 12 // typo support
        ]

        guard let month = months[monthName.lowercased()],
              let day = Int(dayString) else { return nil }

        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.month = month
        comps.day = day

        if let yStr = yearString, let y = Int(yStr) {
            comps.year = y
        }

        // default time: noon
        comps.hour = 12
        comps.minute = 0
        comps.second = 0

        var date = cal.date(from: comps)

        // If no year and date already passed this year, assume next year
        if yearString == nil, let d = date, d < now {
            comps.year = (comps.year ?? cal.component(.year, from: now)) + 1
            date = cal.date(from: comps)
        }

        guard let finalDate = date else { return nil }

        let title = ns
            .replacingCharacters(in: match.range, with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (title, finalDate)
    }

    // MARK: - Relative helpers (today / tomorrow / weekday / time)

    private static func weekday(from text: String) -> Int? { // 1=Sun ... 7=Sat
        let map: [String: Int] = [
            "sunday": 1, "sun": 1,
            "monday": 2, "mon": 2,
            "tuesday": 3, "tue": 3, "tues": 3,
            "wednesday": 4, "wed": 4,
            "thursday": 5, "thu": 5, "thurs": 5,
            "friday": 6, "fri": 6,
            "saturday": 7, "sat": 7
        ]
        for (k, v) in map where text.contains(k) { return v }
        return nil
    }

    private static func next(_ weekday: Int, now: Date) -> Date? {
        var cal = Calendar.current
        cal.firstWeekday = 2
        let today = cal.component(.weekday, from: now)
        var offset = weekday - today
        if offset <= 0 { offset += 7 }
        return cal.date(byAdding: .day, value: offset, to: now)
    }

    private static func extractTime(from text: String) -> (hour: Int, minute: Int)? {
        let regexes = [
            #"\b(\d{1,2}):(\d{2})\s*(am|pm)?\b"#,
            #"\b(\d{1,2})\s*(am|pm)\b"#
        ]

        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)

        for r in regexes {
            guard let re = try? NSRegularExpression(pattern: r) else { continue }
            if let match = re.firstMatch(in: text, options: [], range: range) {
                if r.contains(":"), match.numberOfRanges >= 4 {
                    let h = Int(ns.substring(with: match.range(at: 1))) ?? 0
                    let mn = Int(ns.substring(with: match.range(at: 2))) ?? 0
                    let ampm = match.range(at: 3).location != NSNotFound
                        ? ns.substring(with: match.range(at: 3))
                        : nil
                    return normalize(hour: h, minute: mn, ampm: ampm)
                } else if match.numberOfRanges >= 3 {
                    let h = Int(ns.substring(with: match.range(at: 1))) ?? 0
                    let ampm = ns.substring(with: match.range(at: 2))
                    return normalize(hour: h, minute: 0, ampm: ampm)
                }
            }
        }
        return nil
    }

    private static func normalize(hour: Int, minute: Int, ampm: String?) -> (hour: Int, minute: Int) {
        var h = hour % 24
        let m = minute % 60
        if let ampm = ampm?.lowercased() {
            if ampm == "am" {
                if h == 12 { h = 0 }
            } else if ampm == "pm" {
                if h < 12 { h += 12 }
            }
        }
        return (h, m)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: App

@main
struct QuickTodoApp: App {
    var container: ModelContainer = {
        let schema = Schema([TaskItem.self, CategoryItem.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: false)
        let c = try! ModelContainer(for: schema, configurations: config)
        SwiftDataBridge.shared.modelContainer = c
        return c
    }()

    init() {
        NotificationManager.shared.configure()
        NotificationManager.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup { RootView().modelContainer(container) }
            .windowStyle(.titleBar)
            .commands { AppCommands() }

        // Menu bar quick-add
        MenuBarExtra("QuickTodo", systemImage: "checkmark.circle") {
            MenuBarView().modelContainer(container)
        }
        .menuBarExtraStyle(.window)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Views

struct RootView: View {
    @Environment(\.modelContext) private var context

    @State private var quickText: String = ""
    @State private var includeCompleted: Bool = false
    @State private var search: String = ""
    @State private var selectedCategory: String = "All"

    @State private var newSubjectName: String = ""
    @State private var showManageSubjects = false

    @FocusState private var quickFieldFocused: Bool
    @State private var today = Date()
    let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .full
        return df
    }()

    @Query(filter: TaskItem.upcomingPredicate()) private var tasks: [TaskItem]
    @Query(sort: \CategoryItem.name, order: .forward) private var categories: [CategoryItem]

    private func ensureDefaultCategories() {
        // Keep one safe default so category pickers never break.
        if categories.isEmpty {
            context.insert(CategoryItem(name: "Inbox"))
            try? context.save()
        }
    }

    private func ensureCategoryExists(named raw: String) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Inbox" }

        if categories.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return name
        } else {
            context.insert(CategoryItem(name: name))
            try? context.save()
            return name
        }
    }

    private var sidebarSubjects: [String] {
        // Hide Inbox from the sidebar to keep it clean. Still used internally as a safe fallback.
        categories.map { $0.name }.filter { $0 != "Inbox" }
    }

    private var countsByCategory: [String: Int] {
        var m: [String: Int] = [:]
        for t in tasks where !t.isCompleted {
            m[t.category, default: 0] += 1
        }
        return m
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar (Subjects)
            List(selection: $selectedCategory) {
                Section {
                    HStack(spacing: 8) {
                        Circle().fill(Categories.fallbackColor(for: "All")).frame(width: 8, height: 8)
                        Text("All")
                        Spacer()
                        Text("\(filtered(tasks).count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag("All")
                }

                Section("Subjects") {
                    ForEach(sidebarSubjects, id: \.self) { name in
                        HStack(spacing: 8) {
                            Circle().fill(Categories.color(for: name, in: categories)).frame(width: 8, height: 8)
                            Text(name)
                                .lineLimit(1)
                            Spacer()
                            if let c = countsByCategory[name], c > 0 {
                                Text("\(c)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.vertical, 2)
                                    .padding(.horizontal, 6)
                                    .background(Color.white.opacity(0.10), in: Capsule())
                            }
                        }
                        .tag(name)
                    }
                }
            }
            .navigationTitle("QuickTodo")
            .navigationSplitViewColumnWidth(min: 210, ideal: 260, max: 320)
        } detail: {
            VStack(spacing: 14) {

                // Top bar: add subject + manage + search (more room now that subjects are in the sidebar)
                HStack(alignment: .center, spacing: 12) {

                    Text(selectedCategory == "All" ? "All" : selectedCategory)
                        .font(.subheadline.weight(.semibold))
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Capsule())

                    HStack(spacing: 10) {
                        TextField("Add class subject", text: $newSubjectName)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 210) // prevents truncation like “subjec…”
                            .help("Add a subject, then use #Subject in Quick Add")

                        Button("Add") {
                            let created = ensureCategoryExists(named: newSubjectName)
                            selectedCategory = created
                            newSubjectName = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)

                        Button("Manage") { showManageSubjects = true }
                            .buttonStyle(.bordered)
                            .tint(Theme.accent)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search", text: $search)
                            .textFieldStyle(.plain)
                            .frame(maxWidth: 320)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.top, 6)
                .padding(.horizontal, 12)

                // Quick Add card
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                            TextField("Quick add: e.g. ‘Submit report tomorrow 9am #Work’", text: $quickText)
                                .textFieldStyle(.plain)
                                .onSubmit(addFromQuickEntry)
                                .submitLabel(.done)
                                .focused($quickFieldFocused)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Spacer()

                        Button(action: addFromQuickEntry) {
                            Label("Add", systemImage: "plus.circle.fill").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }

                    Text(dateFormatter.string(from: today))
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 3)
                .padding(.horizontal, 8)
                .padding(.bottom, 12)

                // Task grid / empty state
                TaskListView(tasks: filtered(tasks), categoryColor: { name in Categories.color(for: name, in: categories) }, onToggle: toggle, onDelete: delete, onEdit: edit)
                    .animation(.snappy(duration: 0.25), value: tasks)
            }
            .onAppear {
                ensureDefaultCategories()

                // Refresh automatically at midnight
                if let midnight = Calendar.current.nextDate(after: Date(),
                    matching: DateComponents(hour: 0),
                    matchingPolicy: .nextTime) {
                    let delay = midnight.timeIntervalSinceNow
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        today = Date()
                    }
                }
            }
            .sheet(isPresented: $showManageSubjects) {
                NavigationStack {
                    ManageSubjectsView(selectedCategory: $selectedCategory)
                        .navigationTitle("Manage Subjects")
                        .toolbar {
                            ToolbarItemGroup {
                                Button("Done") { showManageSubjects = false }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .frame(maxWidth: 1200)
            .padding(.vertical, 16)
            .padding(.horizontal, 16)
            .background(Theme.bg)
            .preferredColorScheme(.dark)
        }
    }

private func filtered(_ input: [TaskItem]) -> [TaskItem] {
        let base = includeCompleted ? input : input.filter { !$0.isCompleted }
        let byCategory = (selectedCategory == "All") ? base : base.filter { $0.category == selectedCategory }
        if search.isEmpty { return byCategory.sorted(by: sortRule) }
        return byCategory.filter { $0.title.localizedCaseInsensitiveContains(search) || $0.notes.localizedCaseInsensitiveContains(search) }
            .sorted(by: sortRule)
    }
    private func addFromQuickEntry() {
        let parsed = QuickDateParser.parse(quickText)
        guard !parsed.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        
        withAnimation(.snappy(duration: 0.25)) {
            
            let rawCategory = parsed.category ?? (selectedCategory == "All" ? "Inbox" : selectedCategory)
            let finalCategory = ensureCategoryExists(named: rawCategory)

            let item = TaskItem(
                title: parsed.title,
                notes: "",
                dueDate: parsed.date,
                category: finalCategory
            )
            context.insert(item)
            try? context.save()
            if parsed.date != nil { NotificationManager.shared.schedule(for: item) }
            quickText = ""
            quickFieldFocused = false   // optional: remove focus after adding
        }
    }

    private func sortRule(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch (a.isCompleted, b.isCompleted) {
        case (true, false): return false
        case (false, true): return true
        default:
            switch (a.dueDate, b.dueDate) {
            case let (d1?, d2?): return d1 < d2
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.createdAt < b.createdAt
            }
        }
    }

    private func selectedCategoryOrInbox() -> String { selectedCategory == "All" ? "Inbox" : selectedCategory }

    private func toggle(_ task: TaskItem) {
        withAnimation(.snappy(duration: 0.60)) {
            task.isCompleted.toggle()
            if task.isCompleted { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            task.completedAt = task.isCompleted ? .now : nil
            if task.isCompleted { NotificationManager.shared.cancel(for: task) }
            try? context.save()
        }
    }

    private func delete(_ task: TaskItem) {
        withAnimation(.snappy(duration: 0.25)) {
            NotificationManager.shared.cancel(for: task)
            context.delete(task)
            try? context.save()
        }
    }

    private func edit(_ task: TaskItem, title: String, notes: String, due: Date?, category: String) {
        task.title = title
        task.notes = notes
        task.dueDate = due
        task.category = category
        NotificationManager.shared.cancel(for: task)
        if let _ = due, !task.isCompleted { NotificationManager.shared.schedule(for: task) }
        try? context.save()
    }
}

struct TaskListView: View {
    let tasks: [TaskItem]
    let categoryColor: (String) -> Color
    let onToggle: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    let onEdit: (TaskItem, String, String, Date?, String) -> Void

    var body: some View {
        ScrollView {
            if tasks.isEmpty {
                VStack {
                    Spacer(minLength: 80)
                    EmptyState()
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // inside TaskListView
                let tileWidth: CGFloat = 300 // tile width; tweak 280–320 for your taste
                let columns = Array(
                    repeating: GridItem(.fixed(tileWidth), spacing: 16, alignment: .top),
                    count: 3 // exactly 3 columns
                )

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(tasks) { task in
                        TaskRow(task: task, categoryColor: categoryColor, onToggle: onToggle, onDelete: onDelete) { item, title, notes, due, category in
                            onEdit(item, title, notes, due, category)
                        }
                        .id(task.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 8)

            }
        }
        .background(Theme.bg)
    }
}

struct TaskRow: View {
    @State private var isEditing = false
    @FocusState private var titleFocused: Bool
    @State private var didAppear = false


    let task: TaskItem
    let categoryColor: (String) -> Color
    let onToggle: (TaskItem) -> Void
    let onDelete: (TaskItem) -> Void
    let onEdit: (TaskItem, String, String, Date?, String) -> Void

    var dueColor: Color {
        guard let due = task.dueDate, !task.isCompleted else { return .secondary }
        if due < Date() { return Theme.critical }
        if due < Date().addingTimeInterval(60*60*24) { return Theme.dueSoon }
        return .secondary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Button(action: { onToggle(task) }) {
                    Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isCompleted ? Theme.accent : .secondary)
                        .imageScale(.large)
                        .symbolEffect(.bounce, options: .speed(0.6), value: task.isCompleted)
                        .animation(.spring(response: 0.60, dampingFraction: 0.65), value: task.isCompleted)
                        .accessibilityLabel(task.isCompleted ? "Mark as not completed" : "Mark as completed")
                }

                if isEditing {
                    EditableFields(task: task) { title, notes, due, category in
                        onEdit(task, title, notes, due, category)
                        isEditing = false
                    }
                    .focused($titleFocused)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(task.title)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(
                                    task.isCompleted
                                    ? .secondary
                                    : categoryColor(task.category)
                                )
                                .strikethrough(task.isCompleted)
                                .opacity(task.isCompleted ? 0.65 : 1)
                                .contentTransition(.opacity)
                                .animation(.easeInOut(duration: 0.45), value: task.isCompleted)

                            // Category badge
                            Text(task.category)
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(categoryColor(task.category).opacity(0.18))
                                .foregroundStyle(.primary)
                                .clipShape(Capsule())
                        }

                        HStack(spacing: 8) {
                            if let due = task.dueDate {
                                Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                    .font(.caption)
                                    .foregroundStyle(categoryColor(task.category).opacity(0.85))
                            }
                            if !task.notes.isEmpty {
                                Label(task.notes, systemImage: "note.text")
                                    .font(.caption)
                                    .foregroundStyle(categoryColor(task.category).opacity(0.65))
                            }
                        }

                    }

                    Spacer()

                    Menu {
                        Button("Edit", action: { isEditing = true; titleFocused = true })
                        Button(role: .destructive) { onDelete(task) } label: { Label("Delete", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle").imageScale(.large)
                    }
                    .menuStyle(.borderlessButton)
                }
            }
        }
        .padding(9)
        // Keep every card the same height so short titles don't create smaller tiles.
        // If the user is editing, allow the card to grow.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 135, maxHeight: isEditing ? nil : 135, alignment: .leading)
        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
        .scaleEffect(didAppear ? 1.0 : 0.98)
        .opacity(didAppear ? 1.0 : 0.0) // optional: fade the content too
        .animation(.easeOut(duration: 0.45), value: didAppear)
        .onAppear {
            // slight delay to make the fade noticeable during inserts
            withAnimation(.easeOut(duration: 0.45).delay(0.05)) { didAppear = true }
        }
        .onDisappear { didAppear = false } // so it replays when reinserted

        .glassCard(tint: categoryColor(task.category), completed: task.isCompleted)


        .accessibilityElement(children: .combine)
        .accessibilityLabel("Task: \(task.title)")
        .animation(.snappy(duration: 0.45), value: task.isCompleted)
    }
}

struct EditableFields: View {
    @Query(sort: \CategoryItem.name, order: .forward) private var categories: [CategoryItem]
    @State private var title: String
    @State private var notes: String
    @State private var dueDate: Date?
    @State private var category: String

    let onCommit: (String, String, Date?, String) -> Void

    init(task: TaskItem, onCommit: @escaping (String, String, Date?, String) -> Void) {
        _title = State(initialValue: task.title)
        _notes = State(initialValue: task.notes)
        _dueDate = State(initialValue: task.dueDate)
        _category = State(initialValue: task.category)
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Notes", text: $notes, axis: .vertical).textFieldStyle(.roundedBorder)

            HStack {
                Text("Category")
                Spacer()
                Picker("", selection: $category) {
                    ForEach(categories) { cat in
                        HStack {
                                Circle()
                                    .fill(Categories.color(for: cat))
                                    .frame(width: 10, height: 10)
                                Text(cat.name)
                                Spacer()
                                if cat.name == "Inbox" {
                                    Text("Required")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }.tag(cat.name)
                    
                    }
                }.pickerStyle(.menu)
            }

            HStack {
                DatePicker("Due", selection: Binding($dueDate, default: Date()), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                if dueDate != nil { Button("Clear") { dueDate = nil } }
                Spacer()
                Button("Save") { onCommit(title, notes, dueDate, category) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
        }
    }
}

// Helper to bind optional Date in DatePicker
extension Binding where Value == Date {
    init(_ source: Binding<Date?>, default defaultValue: Date) {
        self.init(get: { source.wrappedValue ?? defaultValue }, set: { newValue in source.wrappedValue = newValue })
    }
}
struct ManageSubjectsView: View {
    @Environment(\.modelContext) private var context
    @Binding var selectedCategory: String

    @State private var pendingDelete: CategoryItem? = nil
    @State private var showConfirmDelete = false
    @State private var categories: [CategoryItem] = []

    var body: some View {
        List {
            if categories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("No subjects yet")
                        .font(.headline)
                    Text("Add a subject from the main screen, then manage it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            } else {
                Section("Subjects") {
                    ForEach(categories) { cat in
                        HStack {
                            Circle()
                                .fill(Categories.color(for: cat))
                                .frame(width: 10, height: 10)
                            Text(cat.name)

                            ColorPicker(
                                "",
                                selection: Binding(
                                    get: { Categories.color(for: cat) },
                                    set: { newColor in
                                        cat.colorHex = newColor.toHex()
                                        try? context.save()
                                    }
                                )
                            )
                            .labelsHidden()
                            .frame(width: 52)

                            Spacer()
                            if cat.name == "Inbox" {
                                Text("Required")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            if cat.name != "Inbox" {
                                Button(role: .destructive) {
                                    pendingDelete = cat
                                    showConfirmDelete = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .contextMenu {
                            if cat.name != "Inbox" {
                                Button(role: .destructive) {
                                    pendingDelete = cat
                                    showConfirmDelete = true
                                } label: {
                                    Text("Delete")
                                }
                            }
                        }
                    }
                    .onDelete(perform: handleDelete)
                }
            }
        }
        // On macOS sheets, List can collapse to almost zero height unless you give it a frame.
        .frame(minWidth: 520, minHeight: 360)
        .task { reload() }
        .alert("Delete Subject?", isPresented: $showConfirmDelete, presenting: pendingDelete) { cat in
            Button("Delete", role: .destructive) { delete(cat) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { cat in
            Text("This will move any tasks in \(cat.name) to Inbox.")
        }
    }

    private func handleDelete(_ indexSet: IndexSet) {
        // Supports swipe-to-delete / delete-key in the List.
        for idx in indexSet {
            let cat = categories[idx]
            if cat.name == "Inbox" { continue }
            pendingDelete = cat
            showConfirmDelete = true
            break // confirm one at a time
        }
    }

    private func reload() {
        let fd = FetchDescriptor<CategoryItem>(sortBy: [SortDescriptor(\CategoryItem.name, order: .forward)])
        categories = (try? context.fetch(fd)) ?? []
        ensureDefaultsIfNeeded()
        // refresh after possibly inserting Inbox
        categories = (try? context.fetch(fd)) ?? []
    }

    private func ensureDefaultsIfNeeded() {
        if categories.first(where: { $0.name == "Inbox" }) == nil {
            context.insert(CategoryItem(name: "Inbox"))
            try? context.save()
        }
    }

    private func delete(_ cat: CategoryItem) {
        guard cat.name != "Inbox" else { return }

        // Move tasks from this category to Inbox
        let fetch = FetchDescriptor<TaskItem>()
        if let allTasks = try? context.fetch(fetch) {
            for t in allTasks where t.category == cat.name {
                t.category = "Inbox"
            }
        }

        context.delete(cat)
        try? context.save()

        if selectedCategory == cat.name { selectedCategory = "All" }
        pendingDelete = nil
        reload()
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Theme.cardFill)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 72, height: 72)

            Text("You're all caught up").font(.title3).fontWeight(.semibold)
            Text("Type above to add your first task.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Menu & Shortcuts

struct AppCommands: Commands {
    @FocusedValue(\.taskActions) var actions

    var body: some Commands {
        CommandMenu("Tasks") {
            Button("New Task", action: { actions?.newTask() }).keyboardShortcut("n", modifiers: [.command])
            Button("Toggle Complete", action: { actions?.toggleSelected() }).keyboardShortcut(.space, modifiers: [])
        }
    }
}

struct TaskActionsKey: FocusedValueKey { typealias Value = TaskActions }
extension FocusedValues { var taskActions: TaskActions? { get { self[TaskActionsKey.self] } set { self[TaskActionsKey.self] = newValue } } }
struct TaskActions { let newTask: () -> Void; let toggleSelected: () -> Void }

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Menu Bar Quick Add View

struct MenuBarView: View {
    @Environment(\.modelContext) private var context
    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                TextField("Quick add… (#tag optional)", text: $text)
                    .textFieldStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [])

            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))

            Button { save() } label: { Label("Add Task", systemImage: "plus.circle.fill") }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func save() {
        let parsed = QuickDateParser.parse(text)
        guard !parsed.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let item = TaskItem(title: parsed.title, notes: "", dueDate: parsed.date, category: parsed.category ?? "Inbox")
        context.insert(item)
        try? context.save()
        if parsed.date != nil { NotificationManager.shared.schedule(for: item) }
        text = ""
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared Card Style (Glassmorphism)

struct GlassCard: ViewModifier {
    let tint: Color
    let isCompleted: Bool

    func body(content: Content) -> some View {
content
    .padding(14)
    .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(isCompleted ? 0.10 : 0.30),
                        Color.black.opacity(0.60)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: tint.opacity(isCompleted ? 0.18 : 0.35),
                radius: 18,
                x: 0,
                y: 10
            )
    )
    }
}

extension View {
    func glassCard(tint: Color, completed: Bool) -> some View {
self.modifier(GlassCard(tint: tint, isCompleted: completed))
    }
}

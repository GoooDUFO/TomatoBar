import KeyboardShortcuts
import LaunchAtLogin
import SwiftUI

extension KeyboardShortcuts.Name {
    static let startStopTimer = Self("startStopTimer")
}

private struct IntervalsView: View {
    @EnvironmentObject var timer: TBTimer
    private var minStr = NSLocalizedString("IntervalsView.min", comment: "min")

    var body: some View {
        VStack {
            Stepper(value: $timer.workIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.workIntervalLength.label",
                                           comment: "Work interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.workIntervalLength))
                }
            }
            Stepper(value: $timer.shortRestIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.shortRestIntervalLength.label",
                                           comment: "Short rest interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.shortRestIntervalLength))
                }
            }
            Stepper(value: $timer.longRestIntervalLength, in: 1 ... 60) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.longRestIntervalLength.label",
                                           comment: "Long rest interval label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String.localizedStringWithFormat(minStr, timer.longRestIntervalLength))
                }
            }
            .help(NSLocalizedString("IntervalsView.longRestIntervalLength.help",
                                    comment: "Long rest interval hint"))
            Stepper(value: $timer.workIntervalsInSet, in: 1 ... 10) {
                HStack {
                    Text(NSLocalizedString("IntervalsView.workIntervalsInSet.label",
                                           comment: "Work intervals in a set label"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(timer.workIntervalsInSet)")
                }
            }
            .help(NSLocalizedString("IntervalsView.workIntervalsInSet.help",
                                    comment: "Work intervals in set hint"))
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }
}

private struct SettingsView: View {
    @EnvironmentObject var timer: TBTimer
    @ObservedObject private var launchAtLogin = LaunchAtLogin.observable

    var body: some View {
        VStack {
            KeyboardShortcuts.Recorder(for: .startStopTimer) {
                Text(NSLocalizedString("SettingsView.shortcut.label",
                                       comment: "Shortcut label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: $timer.stopAfterBreak) {
                Text(NSLocalizedString("SettingsView.stopAfterBreak.label",
                                       comment: "Stop after break label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Toggle(isOn: $timer.showTimerInMenuBar) {
                Text(NSLocalizedString("SettingsView.showTimerInMenuBar.label",
                                       comment: "Show timer in menu bar label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
                .onChange(of: timer.showTimerInMenuBar) { _ in
                    timer.updateTimeLeft()
                }
            Toggle(isOn: $launchAtLogin.isEnabled) {
                Text(NSLocalizedString("SettingsView.launchAtLogin.label",
                                       comment: "Launch at login label"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.toggleStyle(.switch)
            Spacer().frame(minHeight: 0)
        }
        .padding(4)
    }
}

private struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        Slider(value: $volume, in: 0...2) {
            Text(String(format: "%.1f", volume))
        }.gesture(TapGesture(count: 2).onEnded({
            volume = 1.0
        }))
    }
}

private struct SoundsView: View {
    @EnvironmentObject var player: TBPlayer

    private var columns = [
        GridItem(.flexible()),
        GridItem(.fixed(110))
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("SoundsView.isWindupEnabled.label",
                                   comment: "Windup label"))
            VolumeSlider(volume: $player.windupVolume)
            Text(NSLocalizedString("SoundsView.isDingEnabled.label",
                                   comment: "Ding label"))
            VolumeSlider(volume: $player.dingVolume)
            Text(NSLocalizedString("SoundsView.isTickingEnabled.label",
                                   comment: "Ticking label"))
            VolumeSlider(volume: $player.tickingVolume)
        }.padding(4)
        Spacer().frame(minHeight: 0)
    }
}

private enum ChildView {
    case intervals, settings, sounds, sessions, stats
}

private let tomatoColor = Color(red: 0.92, green: 0.34, blue: 0.27)

// MARK: - Stats dashboard

/// A single completed day in the stats window.
private struct TBDayBucket: Identifiable {
    let id = UUID()
    let date: Date
    let count: Int
    let isToday: Bool
}

/// Derived statistics computed from the full persisted sessions history.
private struct TBStats {
    let todayCount: Int
    let weekCount: Int
    let totalCount: Int
    let totalFocusSeconds: Double
    let streak: Int
    let week: [TBDayBucket]
    let firstDate: Date?

    static let empty = TBStats(todayCount: 0, weekCount: 0, totalCount: 0,
                               totalFocusSeconds: 0, streak: 0, week: [], firstDate: nil)

    init(todayCount: Int, weekCount: Int, totalCount: Int, totalFocusSeconds: Double,
         streak: Int, week: [TBDayBucket], firstDate: Date?) {
        self.todayCount = todayCount
        self.weekCount = weekCount
        self.totalCount = totalCount
        self.totalFocusSeconds = totalFocusSeconds
        self.streak = streak
        self.week = week
        self.firstDate = firstDate
    }

    init(from sessions: [TBCompletedSession]) {
        guard !sessions.isEmpty else { self = .empty; return }
        let cal = Calendar.current

        // Bucket counts by local calendar day.
        var counts: [Date: Int] = [:]
        var focus: Double = 0
        for s in sessions {
            let day = cal.startOfDay(for: s.end)
            counts[day, default: 0] += 1
            focus += max(0, s.end.timeIntervalSince(s.start))
        }

        let today = cal.startOfDay(for: Date())
        todayCount = counts[today] ?? 0
        totalCount = sessions.count
        totalFocusSeconds = focus
        firstDate = sessions.map(\.end).min()

        // Last 7 calendar days, oldest → today.
        var buckets: [TBDayBucket] = []
        var weekSum = 0
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let c = counts[day] ?? 0
            weekSum += c
            buckets.append(TBDayBucket(date: day, count: c, isToday: offset == 0))
        }
        week = buckets
        weekCount = weekSum

        // Current streak: consecutive days with ≥1 pomodoro ending at the most
        // recent active day (today if active, else the latest active day).
        let activeDays = Set(counts.filter { $0.value > 0 }.keys)
        var streakCount = 0
        if let latest = activeDays.max() {
            var cursor = latest
            while activeDays.contains(cursor) {
                streakCount += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
                cursor = prev
            }
        }
        streak = streakCount
    }

    var focusString: String {
        let minutes = totalFocusSeconds / 60
        if minutes >= 60 {
            return String(format: "%.1fh", minutes / 60)
        }
        return "\(Int(minutes.rounded()))m"
    }
}

/// One cell of the month heatmap. `day == nil` is a leading blank pad.
private struct TBMonthCell: Identifiable {
    let id = UUID()
    let day: Int?
    let count: Int
    let isToday: Bool
}

/// Per-month statistics for the Stats → Month scope.
private struct TBMonthStats {
    let title: String
    let total: Int
    let activeDays: Int
    let bestCount: Int
    let focusSeconds: Double
    let cells: [TBMonthCell]
    let maxCount: Int
    let canGoForward: Bool

    init(sessions: [TBCompletedSession], monthOffset: Int) {
        let cal = Calendar.current
        let now = Date()
        let anchor = cal.date(byAdding: .month, value: monthOffset,
                              to: cal.startOfDay(for: now)) ?? now
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: anchor)) ?? anchor
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30

        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "LLLL yyyy"
        title = titleFormatter.string(from: monthStart)

        var counts: [Int: Int] = [:]
        var focus: Double = 0
        for session in sessions
        where cal.isDate(session.end, equalTo: monthStart, toGranularity: .month) {
            counts[cal.component(.day, from: session.end), default: 0] += 1
            focus += max(0, session.end.timeIntervalSince(session.start))
        }

        total = counts.values.reduce(0, +)
        activeDays = counts.count
        bestCount = counts.values.max() ?? 0
        focusSeconds = focus
        maxCount = max(counts.values.max() ?? 0, 1)
        canGoForward = monthOffset < 0

        // Pad so day 1 lands under its real weekday column.
        let pad = (cal.component(.weekday, from: monthStart) - cal.firstWeekday + 7) % 7
        var built = (0 ..< pad).map { _ in TBMonthCell(day: nil, count: 0, isToday: false) }
        let today = cal.startOfDay(for: now)
        for day in 1 ... daysInMonth {
            let date = cal.date(byAdding: .day, value: day - 1, to: monthStart)
            built.append(TBMonthCell(day: day,
                                     count: counts[day] ?? 0,
                                     isToday: date.map { cal.isDate($0, inSameDayAs: today) } ?? false))
        }
        cells = built
    }

    var focusString: String {
        let minutes = focusSeconds / 60
        return minutes >= 60 ? String(format: "%.1fh", minutes / 60) : "\(Int(minutes.rounded()))m"
    }

    var averageString: String {
        guard activeDays > 0 else { return "0" }
        return String(format: "%.1f", Double(total) / Double(activeDays))
    }
}

private struct MonthGrid: View {
    let stats: TBMonthStats

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    }

    private var weekdaySymbols: [String] {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let offset = cal.firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(stats.cells) { cell in
                    ZStack {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(fillColor(for: cell))
                        if cell.isToday {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(tomatoColor, lineWidth: 1)
                        }
                        if cell.count > 0 {
                            Text("\(cell.count)")
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundColor(.white)
                        }
                    }
                    .frame(height: 15)
                    .opacity(cell.day == nil ? 0 : 1)
                }
            }
        }
    }

    private func fillColor(for cell: TBMonthCell) -> Color {
        guard cell.count > 0 else { return Color.gray.opacity(0.12) }
        let ratio = Double(cell.count) / Double(stats.maxCount)
        return tomatoColor.opacity(0.35 + 0.65 * ratio)
    }
}

private struct CompactStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StatCard: View {
    let value: String
    let label: String
    let systemImage: String
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundColor(tint)
                Text(value)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundColor(.primary)
            }
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.12)))
    }
}

private struct WeekBarChart: View {
    let week: [TBDayBucket]

    private let dayFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "EEEEE" // narrow weekday: M T W T F S S
        return df
    }()
    private var maxCount: Int { max(week.map(\.count).max() ?? 0, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(week) { day in
                VStack(spacing: 3) {
                    Text(day.count > 0 ? "\(day.count)" : " ")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundColor(day.isToday ? tomatoColor : .secondary)
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.10))
                            .frame(height: 40)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(day.isToday ? tomatoColor : tomatoColor.opacity(0.45))
                            .frame(height: barHeight(day.count))
                    }
                    .frame(height: 40)
                    Text(dayFormatter.string(from: day.date))
                        .font(.system(size: 8))
                        .foregroundColor(day.isToday ? tomatoColor : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func barHeight(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return max(5, 40 * CGFloat(count) / CGFloat(maxCount))
    }
}

private struct MiniStat: View {
    let emoji: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 1) {
            Text(emoji).font(.system(size: 13))
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundColor(.primary)
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private enum StatsScope {
    case week, month
}

private struct StatsView: View {
    @State private var sessions: [TBCompletedSession] = []
    @State private var stats = TBStats.empty
    @State private var scope = StatsScope.week
    @State private var monthOffset = 0
    @State private var loaded = false

    private let captionFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df
    }()

    private var month: TBMonthStats {
        TBMonthStats(sessions: sessions, monthOffset: monthOffset)
    }

    var body: some View {
        Group {
            if loaded && stats.totalCount == 0 {
                VStack {
                    Spacer()
                    Text(NSLocalizedString("StatsView.empty.label",
                                           comment: "Stats empty label"))
                        .foregroundColor(.secondary)
                        .font(.system(.caption))
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 6) {
                    Picker("", selection: $scope) {
                        Text(NSLocalizedString("StatsView.scope.week.label",
                                               comment: "Week scope")).tag(StatsScope.week)
                        Text(NSLocalizedString("StatsView.scope.month.label",
                                               comment: "Month scope")).tag(StatsScope.month)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    switch scope {
                    case .week:
                        weekContent
                    case .month:
                        monthContent
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(4)
        .onAppear {
            sessions = TBSessionsReader.loadAll()
            stats = TBStats(from: sessions)
            loaded = true
        }
    }

    private var weekContent: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                StatCard(value: "\(stats.todayCount)",
                         label: NSLocalizedString("StatsView.today.label",
                                                  comment: "Today label"),
                         systemImage: "sun.max.fill",
                         tint: tomatoColor)
                StatCard(value: "\(stats.weekCount)",
                         label: NSLocalizedString("StatsView.week.label",
                                                  comment: "This week label"),
                         systemImage: "calendar")
            }

            WeekBarChart(week: stats.week)

            Divider()

            HStack(spacing: 4) {
                MiniStat(emoji: "🍅", value: "\(stats.totalCount)",
                         label: NSLocalizedString("StatsView.total.label",
                                                  comment: "Total label"))
                MiniStat(emoji: "⏱", value: stats.focusString,
                         label: NSLocalizedString("StatsView.focus.label",
                                                  comment: "Focus label"))
                MiniStat(emoji: "🔥", value: "\(stats.streak)",
                         label: NSLocalizedString("StatsView.streak.label",
                                                  comment: "Streak label"))
            }

            if let first = stats.firstDate {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("StatsView.since.label", comment: "Since label"),
                    captionFormatter.string(from: first)))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var monthContent: some View {
        let stats = month
        return VStack(spacing: 5) {
            HStack {
                Button {
                    monthOffset -= 1
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                Spacer()
                Text(stats.title)
                    .font(.system(.caption).weight(.semibold))
                Spacer()
                Button {
                    monthOffset += 1
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(!stats.canGoForward)
                .opacity(stats.canGoForward ? 1 : 0.25)
            }

            MonthGrid(stats: stats)

            Divider()

            HStack(spacing: 2) {
                CompactStat(value: "\(stats.total)",
                            label: NSLocalizedString("StatsView.total.label",
                                                     comment: "Total label"))
                CompactStat(value: "\(stats.activeDays)",
                            label: NSLocalizedString("StatsView.activeDays.label",
                                                     comment: "Active days label"))
                CompactStat(value: "\(stats.bestCount)",
                            label: NSLocalizedString("StatsView.best.label",
                                                     comment: "Best day label"))
                CompactStat(value: stats.averageString,
                            label: NSLocalizedString("StatsView.average.label",
                                                     comment: "Average label"))
                CompactStat(value: stats.focusString,
                            label: NSLocalizedString("StatsView.focus.label",
                                                     comment: "Focus label"))
            }
        }
    }
}

private struct SessionsView: View {
    @EnvironmentObject var timer: TBTimer
    private let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return df
    }()

    var body: some View {
        Group {
            if timer.completedSessions.isEmpty {
                VStack {
                    Spacer()
                    Text(NSLocalizedString("SessionsView.empty.label",
                                           comment: "Sessions empty label"))
                        .foregroundColor(.secondary)
                        .font(.system(.caption))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(timer.completedSessions) { session in
                            HStack {
                                Text("🍅 #\(session.index)")
                                    .font(.system(.body).monospacedDigit())
                                Spacer()
                                Text("\(timeFormatter.string(from: session.start))–\(timeFormatter.string(from: session.end))")
                                    .font(.system(.body).monospacedDigit())
                                    .foregroundColor(.secondary)
                                Text("✓")
                                    .foregroundColor(.green)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.12))
                            )
                        }
                    }
                    .padding(2)
                }
            }
        }
        .padding(4)
        .onAppear { timer.pruneSessionsIfNewDay() }
    }
}

struct TBPopoverView: View {
    @ObservedObject var timer = TBTimer()
    @State private var buttonHovered = false
    @State private var activeChildView = ChildView.intervals

    private var startLabel = NSLocalizedString("TBPopoverView.start.label", comment: "Start label")
    private var stopLabel = NSLocalizedString("TBPopoverView.stop.label", comment: "Stop label")
    private var pauseLabel = NSLocalizedString("TBPopoverView.pause.label", comment: "Pause label")
    private var resumeLabel = NSLocalizedString("TBPopoverView.resume.label", comment: "Resume label")
    private var pausedLabel = NSLocalizedString("TBPopoverView.paused.label", comment: "Paused label")

    private var isActive: Bool {
        timer.timer != nil || timer.isPaused
    }

    private var defaultButtonText: String {
        if timer.isPaused {
            return "\(pausedLabel) \(timer.timeLeftString)"
        }
        if timer.timer != nil {
            return timer.timeLeftString
        }
        return startLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                // Default content: countdown / start (also handles Enter via defaultAction).
                Button {
                    timer.startStop()
                    TBStatusItem.shared.closePopover(nil)
                } label: {
                    Text(defaultButtonText)
                        /*
                          When appearance is set to "Dark" and accent color is set to "Graphite"
                          "defaultAction" button label's color is set to the same color as the
                          button, making the button look blank. #24
                         */
                        .foregroundColor(Color.white)
                        .font(.system(.body).monospacedDigit())
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .opacity(buttonHovered && isActive ? 0 : 1)
                .allowsHitTesting(!(buttonHovered && isActive))

                // Hover-revealed actions: Pause/Resume + Stop.
                if isActive {
                    HStack(spacing: 6) {
                        Button {
                            timer.pauseResume()
                        } label: {
                            Text(timer.isPaused ? resumeLabel : pauseLabel)
                                .foregroundColor(Color.white)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)

                        Button {
                            timer.startStop()
                            TBStatusItem.shared.closePopover(nil)
                        } label: {
                            Text(stopLabel)
                                .foregroundColor(Color.white)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                    }
                    .opacity(buttonHovered ? 1 : 0)
                    .allowsHitTesting(buttonHovered)
                }
            }
            .onHover { over in
                buttonHovered = over
            }

            Picker("", selection: $activeChildView) {
                Text(NSLocalizedString("TBPopoverView.intervals.label",
                                       comment: "Intervals label")).tag(ChildView.intervals)
                Text(NSLocalizedString("TBPopoverView.sessions.label",
                                       comment: "Sessions label")).tag(ChildView.sessions)
                Text(NSLocalizedString("TBPopoverView.stats.label",
                                       comment: "Stats label")).tag(ChildView.stats)
                Text(NSLocalizedString("TBPopoverView.settings.label",
                                       comment: "Settings label")).tag(ChildView.settings)
                Text(NSLocalizedString("TBPopoverView.sounds.label",
                                       comment: "Sounds label")).tag(ChildView.sounds)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .pickerStyle(.segmented)

            GroupBox {
                switch activeChildView {
                case .intervals:
                    IntervalsView().environmentObject(timer)
                case .sessions:
                    SessionsView().environmentObject(timer)
                case .stats:
                    StatsView()
                case .settings:
                    SettingsView().environmentObject(timer)
                case .sounds:
                    SoundsView().environmentObject(timer.player)
                }
            }
            .frame(height: 252)
            /* Hard clip: tab content can never spill over the picker or the
               About/Quit rows, whatever its intrinsic height turns out to be. */
            .clipped()

            Group {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel()
                } label: {
                    Text(NSLocalizedString("TBPopoverView.about.label",
                                           comment: "About label"))
                    Spacer()
                    Text("⌘ A").foregroundColor(Color.gray)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("a")
                Button {
                    NSApplication.shared.terminate(self)
                } label: {
                    Text(NSLocalizedString("TBPopoverView.quit.label",
                                           comment: "Quit label"))
                    Spacer()
                    Text("⌘ Q").foregroundColor(Color.gray)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
            }
        }
        #if DEBUG
            /*
             After several hours of Googling and trying various StackOverflow
             recipes I still haven't figured a reliable way to auto resize
             popover to fit all it's contents (pull requests are welcome!).
             The following code block is used to determine the optimal
             geometry of the popover.
             */
            .overlay(
                GeometryReader { proxy in
                    debugSize(proxy: proxy)
                }
            )
        #endif
            /* Use values from GeometryReader */
//            .frame(width: 240, height: 276)
            .padding(12)
    }
}

#if DEBUG
    func debugSize(proxy: GeometryProxy) -> some View {
        print("Optimal popover size:", proxy.size)
        return Color.clear
    }
#endif

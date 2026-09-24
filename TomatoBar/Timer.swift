import KeyboardShortcuts
import SwiftState
import SwiftUI

class TBTimer: ObservableObject {
    @AppStorage("stopAfterBreak") var stopAfterBreak = false
    @AppStorage("showTimerInMenuBar") var showTimerInMenuBar = true
    @AppStorage("workIntervalLength") var workIntervalLength = 25
    @AppStorage("shortRestIntervalLength") var shortRestIntervalLength = 5
    @AppStorage("longRestIntervalLength") var longRestIntervalLength = 15
    @AppStorage("workIntervalsInSet") var workIntervalsInSet = 4
    // This preference is "hidden"
    @AppStorage("overrunTimeLimit") var overrunTimeLimit = -60.0

    private var stateMachine = TBStateMachine(state: .idle)
    public let player = TBPlayer()
    private var consecutiveWorkIntervals: Int = 0
    private var notificationCenter = TBNotificationCenter()
    private var finishTime: Date!
    private var timerFormatter = DateComponentsFormatter()
    private var currentWorkStart: Date?
    private var pausedRemainingSeconds: Int = 0
    @Published var timeLeftString: String = ""
    @Published var timer: DispatchSourceTimer?
    @Published var isPaused: Bool = false
    @Published var completedSessions: [TBCompletedSession] = []
    private var dayChangeObservers: [NSObjectProtocol] = []

    init() {
        /*
         * State diagram
         *
         *                 start/stop
         *       +--------------+-------------+
         *       |              |             |
         *       |  start/stop  |  timerFired |
         *       V    |         |    |        |
         * +--------+ |  +--------+  | +--------+
         * | idle   |--->| work   |--->| rest   |
         * +--------+    +--------+    +--------+
         *   A                  A        |    |
         *   |                  |        |    |
         *   |                  +--------+    |
         *   |  timerFired (!stopAfterBreak)  |
         *   |             skipRest           |
         *   |                                |
         *   +--------------------------------+
         *      timerFired (stopAfterBreak)
         *
         */
        stateMachine.addRoutes(event: .startStop, transitions: [
            .idle => .work, .work => .idle, .rest => .idle,
        ])
        stateMachine.addRoutes(event: .timerFired, transitions: [.work => .rest])
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .idle]) { _ in
            self.stopAfterBreak
        }
        stateMachine.addRoutes(event: .timerFired, transitions: [.rest => .work]) { _ in
            !self.stopAfterBreak
        }
        stateMachine.addRoutes(event: .skipRest, transitions: [.rest => .work])

        /*
         * "Finish" handlers are called when time interval ended
         * "End"    handlers are called when time interval ended or was cancelled
         */
        stateMachine.addAnyHandler(.any => .work, handler: onWorkStart)
        stateMachine.addAnyHandler(.work => .rest, order: 0, handler: onWorkFinish)
        stateMachine.addAnyHandler(.work => .any, order: 1, handler: onWorkEnd)
        stateMachine.addAnyHandler(.any => .rest, handler: onRestStart)
        stateMachine.addAnyHandler(.rest => .work, handler: onRestFinish)
        stateMachine.addAnyHandler(.any => .idle, handler: onIdleStart)
        stateMachine.addAnyHandler(.any => .any, handler: { ctx in
            logger.append(event: TBLogEventTransition(fromContext: ctx))
        })

        stateMachine.addErrorHandler { ctx in fatalError("state machine context: <\(ctx)>") }

        timerFormatter.unitsStyle = .positional
        timerFormatter.allowedUnits = [.minute, .second]
        timerFormatter.zeroFormattingBehavior = .pad

        KeyboardShortcuts.onKeyUp(for: .startStopTimer, action: startStop)
        notificationCenter.setActionHandler(handler: onNotificationAction)

        let aem: NSAppleEventManager = NSAppleEventManager.shared()
        aem.setEventHandler(self,
                            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
                            forEventClass: AEEventClass(kInternetEventClass),
                            andEventID: AEEventID(kAEGetURL))

        // Today's sessions survive an app relaunch: rebuild the list from the log.
        completedSessions = TBSessionsReader.loadAll()
            .filter { Calendar.current.isDateInToday($0.end) }
            .sorted { $0.end < $1.end }

        // Drop yesterday's sessions whenever the day may have rolled over while
        // the app stayed open: at midnight, on wake from sleep, and each time
        // the popover opens (its views stay alive, so onAppear alone is not enough).
        let prune: (Notification) -> Void = { [weak self] _ in self?.pruneSessionsIfNewDay() }
        dayChangeObservers = [
            NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil,
                                                   queue: .main, using: prune),
            NotificationCenter.default.addObserver(forName: NSPopover.willShowNotification, object: nil,
                                                   queue: .main, using: prune),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                              object: nil, queue: .main, using: prune),
        ]

        // The status item does not exist yet during init; set the idle title once it does.
        DispatchQueue.main.async { [weak self] in self?.updateTimeLeft() }
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                 withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.forKeyword(AEKeyword(keyDirectObject))?.stringValue else {
            print("url handling error: cannot get url")
            return
        }
        let url = URL(string: urlString)
        guard url != nil,
              let scheme = url!.scheme,
              let host = url!.host else {
            print("url handling error: cannot parse url")
            return
        }
        guard scheme.caseInsensitiveCompare("tomatobar") == .orderedSame else {
            print("url handling error: unknown scheme \(scheme)")
            return
        }
        switch host.lowercased() {
        case "startstop":
            startStop()
        default:
            print("url handling error: unknown command \(host)")
            return
        }
    }

    func startStop() {
        stateMachine <-! .startStop
    }

    func skipRest() {
        stateMachine <-! .skipRest
    }

    func pauseResume() {
        if isPaused {
            // Resume: rebuild the timer with the saved remaining seconds
            finishTime = Date().addingTimeInterval(TimeInterval(pausedRemainingSeconds))
            let queue = DispatchQueue(label: "Timer")
            timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer!.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
            timer!.setEventHandler(handler: onTimerTick)
            timer!.setCancelHandler(handler: onTimerCancel)
            timer!.resume()
            isPaused = false
            if stateMachine.state == .work {
                player.startTicking()
            }
        } else {
            guard timer != nil, finishTime != nil else { return }
            let remaining = max(0, Int(finishTime.timeIntervalSince(Date()).rounded()))
            pausedRemainingSeconds = remaining
            timer?.cancel()
            timer = nil
            isPaused = true
            player.stopTicking()
            refreshMenuBarTitle()
        }
    }

    func updateTimeLeft() {
        if timer != nil, let finishTime = finishTime {
            timeLeftString = timerFormatter.string(from: Date(), to: finishTime)!
        }
        refreshMenuBarTitle()
    }

    /*
     While "Show timer in menu bar" is on, the title always occupies an "MM:SS"
     slot: running shows the countdown, paused shows the frozen time dimmed, and
     idle lays out an invisible placeholder so only the icon is seen. The
     formatter always yields "MM:SS" and the font has monospaced digits, so the
     status item keeps one width in every state and the neighbouring menu bar
     icons never shift when the timer starts or stops.
     */
    func refreshMenuBarTitle() {
        guard showTimerInMenuBar else {
            TBStatusItem.shared.setTitle(title: nil)
            return
        }
        if timer != nil {
            TBStatusItem.shared.setTitle(title: timeLeftString)
        } else if isPaused {
            TBStatusItem.shared.setTitle(title: timeLeftString, dimmed: true)
        } else {
            let placeholder = timerFormatter.string(from: TimeInterval(workIntervalLength * 60))
            TBStatusItem.shared.setTitle(title: placeholder, invisible: true)
        }
    }

    private func startTimer(seconds: Int) {
        finishTime = Date().addingTimeInterval(TimeInterval(seconds))

        let queue = DispatchQueue(label: "Timer")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer!.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        timer!.setEventHandler(handler: onTimerTick)
        timer!.setCancelHandler(handler: onTimerCancel)
        timer!.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func onTimerTick() {
        /* Cannot publish updates from background thread */
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
            let timeLeft = finishTime.timeIntervalSince(Date())
            if timeLeft <= 0 {
                /*
                 Ticks can be missed during the machine sleep.
                 Stop the timer if it goes beyond an overrun time limit.
                 */
                if timeLeft < overrunTimeLimit {
                    stateMachine <-! .startStop
                } else {
                    stateMachine <-! .timerFired
                }
            }
        }
    }

    private func onTimerCancel() {
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
        }
    }

    private func onNotificationAction(action: TBNotification.Action) {
        if action == .skipRest, stateMachine.state == .rest {
            skipRest()
        }
    }

    private func onWorkStart(context _: TBStateMachine.Context) {
        TBStatusItem.shared.setIcon(name: .work)
        player.playWindup()
        player.startTicking()
        currentWorkStart = Date()
        pruneSessionsIfNewDay()
        startTimer(seconds: workIntervalLength * 60)
    }

    /// Keeps only today's sessions, so the Sessions tab and numbering restart
    /// at #1 each day even when the app is never quit.
    func pruneSessionsIfNewDay() {
        let calendar = Calendar.current
        if completedSessions.contains(where: { !calendar.isDateInToday($0.end) }) {
            completedSessions.removeAll { !calendar.isDateInToday($0.end) }
        }
    }

    private func onWorkFinish(context _: TBStateMachine.Context) {
        consecutiveWorkIntervals += 1
        player.playDing()
        let end = Date()
        let start = currentWorkStart ?? end.addingTimeInterval(-Double(workIntervalLength * 60))
        pruneSessionsIfNewDay()
        let session = TBCompletedSession(
            index: completedSessions.count + 1,
            start: start,
            end: end
        )
        completedSessions.append(session)
        sessionsLogger.append(session: session)
        currentWorkStart = nil
    }

    private func onWorkEnd(context _: TBStateMachine.Context) {
        player.stopTicking()
    }

    private func onRestStart(context _: TBStateMachine.Context) {
        var body = NSLocalizedString("TBTimer.onRestStart.short.body", comment: "Short break body")
        var length = shortRestIntervalLength
        var imgName = NSImage.Name.shortRest
        if consecutiveWorkIntervals >= workIntervalsInSet {
            body = NSLocalizedString("TBTimer.onRestStart.long.body", comment: "Long break body")
            length = longRestIntervalLength
            imgName = .longRest
            consecutiveWorkIntervals = 0
        }
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestStart.title", comment: "Time's up title"),
            body: body,
            category: .restStarted
        )
        TBStatusItem.shared.setIcon(name: imgName)
        startTimer(seconds: length * 60)
    }

    private func onRestFinish(context ctx: TBStateMachine.Context) {
        if ctx.event == .skipRest {
            return
        }
        notificationCenter.send(
            title: NSLocalizedString("TBTimer.onRestFinish.title", comment: "Break is over title"),
            body: NSLocalizedString("TBTimer.onRestFinish.body", comment: "Break is over body"),
            category: .restFinished
        )
    }

    private func onIdleStart(context _: TBStateMachine.Context) {
        stopTimer()
        TBStatusItem.shared.setIcon(name: .idle)
        consecutiveWorkIntervals = 0
        isPaused = false
        pausedRemainingSeconds = 0
        currentWorkStart = nil
    }
}

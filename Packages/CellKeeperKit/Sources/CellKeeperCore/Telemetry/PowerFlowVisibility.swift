import Foundation

/// When the menu shows the power flow, and so reads and animates it (D114,
/// D115, D121): the menu's window is on screen, the Mac is awake, and the
/// flow is in the menu, either its diagram at the top or its section under
/// Details expanded. The menu's view outlives each opening (closing the
/// menu only orders its window out), so the reads follow this state, never
/// the view's lifetime.
///
/// Each change says whether it is a hide event: the caller then ends the
/// reading runs and tells the SMC source at once
/// (``PowerFlowRefresher/collapse(_:at:)``). Every hide event also moves
/// ``generation`` on, and the reading tasks' identities include it
/// (``taskID``), so whatever SwiftUI makes of a hide followed at once by a
/// show (a close and reopen, the diagram switched off and on, the section
/// collapsed and expanded, a sleep and wake), the task is started again
/// once the flow is shown.
public struct PowerFlowVisibility: Sendable, Equatable {
    /// Whether the menu's window is on screen, as AppKit reports it.
    public private(set) var isMenuVisible = false
    /// Whether the Mac is between its will-sleep and its wake. Nothing is
    /// read meanwhile, whatever the window reports: its visibility may stay
    /// true through a sleep or a dark wake, or change only late.
    public private(set) var isAsleep = false
    /// Whether the diagram is at the top of the menu (Settings › General).
    public private(set) var showsDiagramAtTop: Bool
    /// Whether the Power flow section under Details is expanded; it counts
    /// only while the diagram is not at the top.
    public private(set) var isSectionExpanded: Bool
    /// How many hide events there have been.
    public private(set) var generation = 0

    public init(showsDiagramAtTop: Bool, isSectionExpanded: Bool) {
        self.showsDiagramAtTop = showsDiagramAtTop
        self.isSectionExpanded = isSectionExpanded
    }

    /// The menu's window is on screen and the Mac awake: the diagram's
    /// links may animate.
    public var isMenuOnScreen: Bool {
        isMenuVisible && !isAsleep
    }

    /// Whether the flow is read: the menu is on screen and shows the
    /// diagram at the top or the expanded section.
    public var isShown: Bool {
        isMenuOnScreen && (showsDiagramAtTop || isSectionExpanded)
    }

    /// The identity of a task that reads while the flow is shown. It
    /// changes at every hide event and whenever the flow starts or stops
    /// being shown, so a task ended by a hide is always started again when
    /// the flow is shown, however quickly the show follows.
    public struct TaskID: Hashable, Sendable {
        public let isShown: Bool
        public let generation: Int
    }

    public var taskID: TaskID {
        TaskID(isShown: isShown, generation: generation)
    }

    /// The menu's window came on screen or left it. Leaving it is a hide
    /// event; coming back is not, and a repeat of the same visibility
    /// changes nothing.
    public mutating func setMenuVisible(_ visible: Bool) -> Bool {
        guard visible != isMenuVisible else { return false }
        isMenuVisible = visible
        return visible ? false : hide()
    }

    /// The section under Details was expanded or collapsed. A hide event
    /// whenever the flow is then not shown; not while the diagram at the
    /// top still shows it, since the section is not in the menu then.
    public mutating func setSectionExpanded(_ expanded: Bool) -> Bool {
        isSectionExpanded = expanded
        return isShown ? false : hide()
    }

    /// The diagram at the top of the menu was switched on or off. Switching
    /// it off is always a hide event, whatever the section's saved state:
    /// while the diagram was on, the section was not in the menu, so no run
    /// of its own was reading; once shown, it starts its own.
    public mutating func setShowsDiagramAtTop(_ shows: Bool) -> Bool {
        guard shows != showsDiagramAtTop else { return false }
        showsDiagramAtTop = shows
        return shows ? false : hide()
    }

    /// The Mac is about to sleep: always a hide event, and nothing is shown
    /// until ``didWake()``, whatever the window reports meanwhile.
    public mutating func willSleep() -> Bool {
        isAsleep = true
        return hide()
    }

    /// The Mac woke. The flow is shown again only if the window is on
    /// screen and the flow is in the menu; the tasks then start again, as
    /// ``taskID`` changed with the sleep's hide event.
    public mutating func didWake() {
        isAsleep = false
    }

    private mutating func hide() -> Bool {
        generation += 1
        return true
    }
}

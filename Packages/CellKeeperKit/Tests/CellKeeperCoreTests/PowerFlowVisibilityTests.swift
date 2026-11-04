import CellKeeperCore
import Foundation
import Testing

/// The menu with its power flow's reading task, as the app runs it: each
/// change goes to the visibility, a hide event ends the runs, and the task
/// is started again only when its identity differs from the one it was
/// last started with, as SwiftUI does when it sees only the final state of
/// several changes.
private struct MenuWithTask {
    var visibility: PowerFlowVisibility
    /// The identity the task was last started with.
    private(set) var startedWith: PowerFlowVisibility.TaskID
    /// Whether a run is reading: started while shown, ended by a hide event.
    private(set) var isReading: Bool
    private(set) var hideEvents = 0

    init(showsDiagramAtTop: Bool = true, isSectionExpanded: Bool = false, visible: Bool = true) {
        visibility = PowerFlowVisibility(showsDiagramAtTop: showsDiagramAtTop, isSectionExpanded: isSectionExpanded)
        _ = visibility.setMenuVisible(visible)
        startedWith = visibility.taskID
        isReading = visibility.isShown
    }

    /// Applies `change`, ending the runs if it is a hide event, without
    /// letting SwiftUI look at the task yet.
    mutating func apply(_ change: (inout PowerFlowVisibility) -> Bool) {
        if change(&visibility) {
            hideEvents += 1
            isReading = false
        }
    }

    /// SwiftUI reconciles the task with the final state: it starts it
    /// again, and the run reads while shown, only if the identity changed.
    mutating func reconcile() {
        guard visibility.taskID != startedWith else { return }
        startedWith = visibility.taskID
        isReading = visibility.isShown
    }
}

@Suite("The power flow stops at sleep and reads again after wake only while the menu is on screen")
struct PowerFlowSleepGateTests {
    @Test("Sleep with the menu open is a hide event, and the flow is not shown while asleep")
    func sleepHides() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: false)
        _ = visibility.setMenuVisible(true)
        #expect(visibility.isShown)
        let before = visibility.generation

        let sleepHid = visibility.willSleep()
        #expect(sleepHid)
        #expect(!visibility.isShown)
        #expect(!visibility.isMenuOnScreen)
        #expect(visibility.isMenuVisible)
        #expect(visibility.generation == before + 1)
    }

    @Test("Nothing the window reports while asleep shows the flow")
    func windowWhileAsleep() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: false, isSectionExpanded: true)
        _ = visibility.willSleep()
        // A late occlusion change, or one during a dark wake.
        _ = visibility.setMenuVisible(false)
        let shownHid = visibility.setMenuVisible(true)
        #expect(!shownHid)
        #expect(!visibility.isShown)
        // Nor does expanding the section or switching the diagram on.
        _ = visibility.setShowsDiagramAtTop(true)
        _ = visibility.setSectionExpanded(true)
        #expect(!visibility.isShown)
    }

    @Test("A wake with the menu on screen and the flow in it shows the flow again, and the task restarts")
    func wakeWithMenuOpen() {
        var menu = MenuWithTask()
        #expect(menu.isReading)
        menu.apply { $0.willSleep() }
        menu.reconcile()
        #expect(!menu.isReading)

        menu.visibility.didWake()
        menu.reconcile()
        #expect(menu.visibility.isShown)
        #expect(menu.isReading)
    }

    @Test("A sleep and wake that SwiftUI sees as one update still restarts the task")
    func sleepAndWakeInOneUpdate() {
        var menu = MenuWithTask()
        menu.apply { $0.willSleep() }
        menu.visibility.didWake()
        menu.reconcile()
        #expect(menu.hideEvents == 1)
        #expect(menu.isReading)
    }

    @Test("A wake with the menu closed shows nothing until the menu opens")
    func wakeWithMenuClosed() {
        var menu = MenuWithTask()
        menu.apply { $0.willSleep() }
        menu.apply { $0.setMenuVisible(false) }
        menu.visibility.didWake()
        menu.reconcile()
        #expect(!menu.visibility.isShown)
        #expect(!menu.isReading)

        menu.apply { $0.setMenuVisible(true) }
        menu.reconcile()
        #expect(menu.isReading)
    }

    @Test("A wake with the flow switched off and the section collapsed shows nothing")
    func wakeWithFlowHidden() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: false, isSectionExpanded: false)
        _ = visibility.setMenuVisible(true)
        _ = visibility.willSleep()
        visibility.didWake()
        #expect(visibility.isMenuOnScreen)
        #expect(!visibility.isShown)
    }
}

@Suite("Every hide event of the power flow restarts its reads when it is shown again")
struct PowerFlowHideGenerationTests {
    /// A hide and a show in one update, from a state reading.
    struct Toggle: CustomTestStringConvertible, Sendable {
        let name: String
        let showsDiagramAtTop: Bool
        let isSectionExpanded: Bool
        let hide: @Sendable (inout PowerFlowVisibility) -> Bool
        let show: @Sendable (inout PowerFlowVisibility) -> Bool

        var testDescription: String { name }
    }

    static let toggles: [Toggle] = [
        Toggle(name: "the menu closed and reopened", showsDiagramAtTop: true, isSectionExpanded: false,
               hide: { $0.setMenuVisible(false) }, show: { $0.setMenuVisible(true) }),
        Toggle(name: "the diagram switched off and on", showsDiagramAtTop: true, isSectionExpanded: false,
               hide: { $0.setShowsDiagramAtTop(false) }, show: { $0.setShowsDiagramAtTop(true) }),
        Toggle(name: "the section collapsed and expanded", showsDiagramAtTop: false, isSectionExpanded: true,
               hide: { $0.setSectionExpanded(false) }, show: { $0.setSectionExpanded(true) }),
        Toggle(name: "a sleep and a wake", showsDiagramAtTop: true, isSectionExpanded: false,
               hide: { $0.willSleep() }, show: { $0.didWake(); return false }),
    ]

    @Test("Each is a hide event and moves the generation on", arguments: toggles)
    func hideEventMovesGeneration(_ toggle: Toggle) {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: toggle.showsDiagramAtTop, isSectionExpanded: toggle.isSectionExpanded)
        _ = visibility.setMenuVisible(true)
        let before = visibility.generation
        let hid = toggle.hide(&visibility)
        #expect(hid)
        #expect(!visibility.isShown)
        #expect(visibility.generation == before + 1)
    }

    @Test("A hide and a show that SwiftUI sees as one update start the task again", arguments: toggles)
    func hideAndShowRestart(_ toggle: Toggle) {
        var menu = MenuWithTask(showsDiagramAtTop: toggle.showsDiagramAtTop, isSectionExpanded: toggle.isSectionExpanded)
        #expect(menu.isReading)
        menu.apply(toggle.hide)
        menu.apply(toggle.show)
        #expect(!menu.isReading)
        menu.reconcile()
        #expect(menu.hideEvents == 1)
        #expect(menu.isReading)
    }

    @Test("Several hides and shows in one update, of every kind, still end with the task reading")
    func manyInOneUpdate() {
        var menu = MenuWithTask()
        for toggle in Self.toggles where toggle.showsDiagramAtTop {
            menu.apply(toggle.hide)
            menu.apply(toggle.show)
        }
        menu.reconcile()
        #expect(menu.hideEvents == 3)
        #expect(menu.isReading)
    }

    @Test("Switching the diagram off with the section expanded is a hide event, and the flow stays shown through the section")
    func diagramOffSectionExpanded() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: true)
        _ = visibility.setMenuVisible(true)
        let before = visibility.taskID
        let switchedOffHid = visibility.setShowsDiagramAtTop(false)
        #expect(switchedOffHid)
        #expect(visibility.isShown)
        #expect(visibility.taskID != before)
    }
}

@Suite("What is not a hide event of the power flow")
struct PowerFlowNotHiddenTests {
    @Test("Collapsing the section while the diagram is at the top keeps the flow shown")
    func collapseWithDiagram() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: true)
        _ = visibility.setMenuVisible(true)
        let before = visibility.taskID
        let collapseHid = visibility.setSectionExpanded(false)
        #expect(!collapseHid)
        #expect(visibility.isShown)
        #expect(visibility.taskID == before)
    }

    @Test("Showing the flow is never a hide event, and changes the task's identity")
    func showing() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: false, isSectionExpanded: false)
        var before = visibility.taskID
        let openHid = visibility.setMenuVisible(true)
        let switchedOnHid = visibility.setShowsDiagramAtTop(true)
        #expect(!openHid)
        #expect(!switchedOnHid)
        #expect(visibility.isShown)
        #expect(visibility.generation == 0)
        #expect(visibility.taskID != before)

        before = visibility.taskID
        visibility.didWake()
        #expect(visibility.taskID == before)
    }

    @Test("A repeat of the window's visibility or of the diagram's switch changes nothing")
    func repeats() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: true, isSectionExpanded: false)
        let closedAgainHid = visibility.setMenuVisible(false)
        _ = visibility.setMenuVisible(true)
        let openAgainHid = visibility.setMenuVisible(true)
        let switchedOnAgainHid = visibility.setShowsDiagramAtTop(true)
        #expect(!closedAgainHid)
        #expect(!openAgainHid)
        #expect(!switchedOnAgainHid)
        #expect(visibility.generation == 0)
        #expect(visibility.isShown)
    }

    @Test("Expanding the section with the diagram off shows the flow")
    func expand() {
        var visibility = PowerFlowVisibility(showsDiagramAtTop: false, isSectionExpanded: false)
        _ = visibility.setMenuVisible(true)
        #expect(!visibility.isShown)
        let expandHid = visibility.setSectionExpanded(true)
        #expect(!expandHid)
        #expect(visibility.isShown)
    }
}

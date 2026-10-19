import CellKeeperKit
import Testing

@Suite("The menu's charge-limit slider")
struct ChargeLimitSliderEditTests {
    /// The model at 80%, revision 5.
    private func edit() -> ChargeLimitSliderEdit {
        ChargeLimitSliderEdit(limit: 80, revision: 5)
    }

    /// Feeds `events` and returns every output, in order.
    private func run(_ slider: inout ChargeLimitSliderEdit, _ events: [ChargeLimitSliderEdit.Event]) -> [ChargeLimitSliderEdit.Output] {
        events.map { slider.handle($0) }
    }

    /// The outputs that change the model.
    private func applies(_ outputs: [ChargeLimitSliderEdit.Output]) -> [ChargeLimitSliderEdit.Output] {
        outputs.filter { if case .apply = $0 { true } else { false } }
    }

    @Test("A change made without a drag is applied after the pause, at the revision it began from")
    func keyboardChange() {
        var slider = edit()
        #expect(slider.handle(.userChanged(81)) == .startTimer(token: 1))
        #expect(slider.shownLimit == 81)
        #expect(slider.handle(.timerFired(token: 1)) == .apply(81, ifRevision: 5))
        #expect(slider.draft == nil)
    }

    @Test("Rapid changes coalesce into one apply of the latest value")
    func rapidChanges() {
        var slider = edit()
        let outputs = run(&slider, [
            .userChanged(81), .userChanged(82), .userChanged(83),
            .timerFired(token: 1), .timerFired(token: 2), .timerFired(token: 3), .timerFired(token: 3),
        ])
        #expect(outputs == [
            .startTimer(token: 1), .startTimer(token: 2), .startTimer(token: 3),
            .nothing, .nothing, .apply(83, ifRevision: 5), .nothing,
        ])
    }

    @Test("A newer command during the pause supersedes the edit; the slider shows the model's limit and the timer does nothing")
    func supersededDuringPause() {
        var slider = edit()
        let outputs = run(&slider, [.userChanged(81), .settingsChanged(revision: 6, limit: 90), .timerFired(token: 1)])
        #expect(outputs == [.startTimer(token: 1), .showModelValue, .nothing])
        #expect(slider.shownLimit == 90)
        #expect(applies(outputs).isEmpty)
    }

    @Test("A newer command that sets the limit the edit began from still wins")
    func supersededBySameValue() {
        var slider = edit()
        let outputs = run(&slider, [.userChanged(81), .settingsChanged(revision: 6, limit: 80), .timerFired(token: 1)])
        #expect(outputs == [.startTimer(token: 1), .showModelValue, .nothing])
        #expect(slider.shownLimit == 80)
    }

    @Test("A newer command during a drag leaves the knob with the pointer, and the drag's end drops the edit")
    func supersededDuringDrag() {
        var slider = edit()
        let outputs = run(&slider, [
            .dragBegan, .userChanged(70), .settingsChanged(revision: 6, limit: 90), .userChanged(65), .dragEnded(65),
        ])
        #expect(outputs == [.nothing, .nothing, .nothing, .nothing, .showModelValue])
        #expect(slider.shownLimit == 90)
        #expect(!slider.isDragging)
    }

    @Test("A drag is applied once, when it ends, with no timer")
    func drag() {
        var slider = edit()
        let outputs = run(&slider, [.dragBegan, .userChanged(70), .userChanged(65), .dragEnded(65)])
        #expect(outputs == [.nothing, .nothing, .nothing, .apply(65, ifRevision: 5)])
    }

    @Test("A drag's end after a pending change applies once; the pending timer then does nothing")
    func dragAfterPendingChange() {
        var slider = edit()
        let outputs = run(&slider, [.userChanged(81), .dragBegan, .userChanged(85), .dragEnded(85), .timerFired(token: 1)])
        #expect(outputs == [.startTimer(token: 1), .nothing, .nothing, .apply(85, ifRevision: 5), .nothing])
    }

    @Test("Closing applies the current edit once, at once; nothing happens after")
    func closeFlushesOnce() {
        var slider = edit()
        let outputs = run(&slider, [
            .userChanged(81), .closed, .timerFired(token: 1), .closed, .userChanged(82), .dragBegan, .dragEnded(83), .timerFired(token: 2),
        ])
        #expect(outputs == [.startTimer(token: 1), .apply(81, ifRevision: 5), .nothing, .nothing, .nothing, .nothing, .nothing, .nothing])
        #expect(applies(outputs).count == 1)
        #expect(slider.isClosed)
    }

    @Test("Closing during a drag applies the edit once; the drag's end after it does nothing")
    func closeDuringDrag() {
        var slider = edit()
        let outputs = run(&slider, [.dragBegan, .userChanged(70), .closed, .dragEnded(70)])
        #expect(outputs == [.nothing, .nothing, .apply(70, ifRevision: 5), .nothing])
    }

    @Test("Closing with no edit, or a superseded one, applies nothing")
    func closeWithoutCurrentEdit() {
        var idle = edit()
        #expect(idle.handle(.closed) == .nothing)

        var superseded = edit()
        let outputs = run(&superseded, [.dragBegan, .userChanged(70), .settingsChanged(revision: 6, limit: 90), .closed])
        #expect(outputs == [.nothing, .nothing, .nothing, .showModelValue])
    }

    @Test("The edit's own apply, fed back, starts the next edit from the new revision")
    func ownApplyFedBack() {
        var slider = edit()
        let outputs = run(&slider, [
            .userChanged(81), .timerFired(token: 1),
            // What the model holds after applying 81.
            .settingsChanged(revision: 6, limit: 81),
            .userChanged(82), .timerFired(token: 2),
        ])
        #expect(outputs == [.startTimer(token: 1), .apply(81, ifRevision: 5), .nothing, .startTimer(token: 2), .apply(82, ifRevision: 6)])
    }

    @Test("A revision fed again changes nothing; a new one without an edit only updates the model's limit")
    func revisionsWithoutEdit() {
        var slider = edit()
        #expect(slider.handle(.settingsChanged(revision: 5, limit: 80)) == .nothing)
        #expect(slider.handle(.settingsChanged(revision: 6, limit: 90)) == .nothing)
        #expect(slider.shownLimit == 90)
        #expect(slider.handle(.userChanged(91)) == .startTimer(token: 1))
        #expect(slider.handle(.settingsChanged(revision: 6, limit: 90)) == .nothing)
        #expect(slider.handle(.timerFired(token: 1)) == .apply(91, ifRevision: 6))
    }
}

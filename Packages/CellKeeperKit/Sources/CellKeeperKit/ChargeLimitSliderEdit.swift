import Foundation

/// The menu's charge-limit slider, as a state machine: the view feeds it
/// events and carries out what it returns (D109).
///
/// - A drag is applied when it ends, so dragging never sends a burst of
///   changes. A change made without a drag (the arrow keys, VoiceOver's
///   increment and decrement) is applied once the value has stayed put for a
///   moment: each one asks for the pause timer again, and only the latest
///   timer counts.
/// - An edit is applied only at the settings revision it began from. Any
///   settings change it did not make, from anywhere (Settings, a Shortcuts
///   action, CellKeeper itself), supersedes it, even one that sets the limit
///   the edit began from: a newer command wins. A superseded edit is dropped
///   and the slider shows the model's limit, at once without a drag and at
///   the end of a drag, so the knob never jumps under the pointer.
/// - When the menu closes, or the slider goes away, the current edit is
///   applied once, at once, if it is still current; nothing happens after
///   that.
public struct ChargeLimitSliderEdit: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The slider moved to a whole percentage, by a drag, a key or
        /// VoiceOver.
        case userChanged(Int)
        case dragBegan
        /// A drag ended at a whole percentage.
        case dragEnded(Int)
        /// The model's settings are at `revision`, with `limit`.
        case settingsChanged(revision: Int, limit: Int)
        /// The pause timer started for `token` fired.
        case timerFired(token: Int)
        /// The menu closed, or the slider went away.
        case closed
    }

    public enum Output: Sendable, Equatable {
        case nothing
        /// Start the pause timer, replacing any running one, and feed
        /// ``Event/timerFired(token:)`` with `token` when it fires.
        case startTimer(token: Int)
        /// Apply the limit if the model's settings are still at `ifRevision`;
        /// then feed ``Event/settingsChanged(revision:limit:)`` with what the
        /// model holds.
        case apply(Int, ifRevision: Int)
        /// The edit was dropped: show the model's limit.
        case showModelValue
    }

    /// The edit in progress, which the slider shows; nil shows the model's
    /// limit.
    public private(set) var draft: Int?
    public private(set) var isDragging = false
    public private(set) var isClosed = false
    /// The model's latest settings revision and limit, as fed.
    public private(set) var revision: Int
    public private(set) var modelLimit: Int
    /// The revision the edit in progress began from.
    private var baseRevision: Int?
    /// The timer a change made without a drag waits for; nil while none.
    private var pendingToken: Int?
    private var lastToken = 0

    public init(limit: Int, revision: Int) {
        self.modelLimit = limit
        self.revision = revision
    }

    /// What the slider shows.
    public var shownLimit: Int {
        draft ?? modelLimit
    }

    public mutating func handle(_ event: Event) -> Output {
        if case .settingsChanged(let newRevision, let limit) = event {
            modelLimit = limit
            guard newRevision != revision else { return .nothing }
            revision = newRevision
            // During a drag the knob stays with the pointer; the drag's end
            // finds the edit superseded.
            guard baseRevision != nil, !isDragging else { return .nothing }
            endEdit()
            return .showModelValue
        }
        guard !isClosed else { return .nothing }
        switch event {
        case .userChanged(let value):
            beginEditIfNeeded()
            draft = value
            guard !isDragging else { return .nothing }
            lastToken += 1
            pendingToken = lastToken
            return .startTimer(token: lastToken)
        case .dragBegan:
            beginEditIfNeeded()
            isDragging = true
            // The drag's end applies the edit.
            pendingToken = nil
            return .nothing
        case .dragEnded(let value):
            beginEditIfNeeded()
            isDragging = false
            draft = value
            return finishEdit()
        case .timerFired(let token):
            guard token == pendingToken, !isDragging else { return .nothing }
            return finishEdit()
        case .closed:
            isClosed = true
            isDragging = false
            return finishEdit()
        case .settingsChanged:
            return .nothing
        }
    }

    private mutating func beginEditIfNeeded() {
        if baseRevision == nil {
            baseRevision = revision
        }
    }

    /// Applies the edit if it is still current, and ends it either way.
    private mutating func finishEdit() -> Output {
        guard let draft, let baseRevision else {
            endEdit()
            return .nothing
        }
        endEdit()
        return baseRevision == revision ? .apply(draft, ifRevision: baseRevision) : .showModelValue
    }

    private mutating func endEdit() {
        draft = nil
        baseRevision = nil
        pendingToken = nil
    }
}

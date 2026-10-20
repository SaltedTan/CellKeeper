/// The words the verdict's reasons use for the two moments a run is judged
/// against, and for what is held between them. The assertion probes
/// (research notes 09–10) speak of an assertion that is created and
/// released; research note 11's manual adapter cut speaks of the owner's
/// cut mark and restore, which only the owner confirms. ``assertion`` is
/// the wording the probe has always printed (`AssertionGoldenTests` holds
/// it to that).
public struct VerdictTerms: Sendable, Equatable {
    /// Why nothing was judged: "the assertion was not created".
    public var notCreated: String
    /// "the probe did not release the assertion itself".
    public var notReleased: String
    /// What the probe did on a sleep notification: "the probe ended the
    /// hold".
    public var onSleep: String
    /// The first moment, after "after": "the assertion was created".
    public var created: String
    /// What is held between the two moments: "the assertion".
    public var held: String
    /// "its creation".
    public var itsCreation: String
    /// "the creation".
    public var creation: String
    /// The second moment: "the release".
    public var release: String
    /// What the baseline comes before: "the assertion".
    public var baselineBefore: String
    /// "the assertion was to be created".
    public var toBeCreated: String
    /// "the assertion was about to be created".
    public var aboutToBeCreated: String
    /// What a failed baseline or freshness check prevented: "nothing was
    /// created".
    public var nothingCreated: String

    public init(
        notCreated: String,
        notReleased: String,
        onSleep: String,
        created: String,
        held: String,
        itsCreation: String,
        creation: String,
        release: String,
        baselineBefore: String,
        toBeCreated: String,
        aboutToBeCreated: String,
        nothingCreated: String
    ) {
        self.notCreated = notCreated
        self.notReleased = notReleased
        self.onSleep = onSleep
        self.created = created
        self.held = held
        self.itsCreation = itsCreation
        self.creation = creation
        self.release = release
        self.baselineBefore = baselineBefore
        self.toBeCreated = toBeCreated
        self.aboutToBeCreated = aboutToBeCreated
        self.nothingCreated = nothingCreated
    }

    /// The assertion probes' wording (notes 09–10).
    public static let assertion = VerdictTerms(
        notCreated: "the assertion was not created",
        notReleased: "the probe did not release the assertion itself",
        onSleep: "the probe ended the hold",
        created: "the assertion was created",
        held: "the assertion",
        itsCreation: "its creation",
        creation: "the creation",
        release: "the release",
        baselineBefore: "the assertion",
        toBeCreated: "the assertion was to be created",
        aboutToBeCreated: "the assertion was about to be created",
        nothingCreated: "nothing was created"
    )

    /// The manual adapter cut's wording (note 11), judged at the owner's cut
    /// mark (`cutnow`). The cut and the restore are owner-confirmed; the
    /// probe observes neither.
    public static let manualCut = VerdictTerms(
        notCreated: "the owner did not confirm the cut (no cut08)",
        notReleased: "the owner did not confirm the restore",
        onSleep: "the probe asked for the read-first steps",
        created: "the owner's cut mark",
        held: "the cut",
        itsCreation: "the cut mark",
        creation: "the cut mark",
        release: "the restore",
        baselineBefore: "the CUT prompt",
        toBeCreated: "the cut was to be marked",
        aboutToBeCreated: "the cut was about to be marked",
        nothingCreated: "the probe printed NO GO"
    )

    /// The manual adapter cut's wording for the baseline, which is judged
    /// when the CUT prompt is to be shown (note 11 §4.5, check a).
    public static let manualCutPrompt: VerdictTerms = {
        var terms = manualCut
        terms.toBeCreated = "the CUT prompt was to be shown"
        terms.aboutToBeCreated = "the CUT prompt was about to be shown"
        terms.nothingCreated = "there was no CUT prompt"
        return terms
    }()
}

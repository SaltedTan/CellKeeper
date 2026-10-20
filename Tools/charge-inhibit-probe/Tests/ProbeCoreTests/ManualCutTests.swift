import Testing

/// Research note 11's manual adapter cut: its suites run one test at a
/// time (the trait applies to every suite nested in an extension of this
/// type).
///
/// Some of them run in real time (a console writer thread, a reminder
/// timer, a pseudo-terminal, waits of up to a few seconds); others are
/// CPU-bound simulations of whole runs. Run side by side with each other,
/// they kept every thread of the Swift concurrency pool busy on a 3-core CI
/// runner, and while that pool's threads are all busy the kernel does not
/// start a new thread for `DispatchQueue.global()`: #98's teardown test,
/// which needs one within 2 s, failed on macOS 27 / Xcode 27 (CI run
/// 39360164356). One at a time, these suites hold at most one of the pool's
/// threads.
@Suite(.serialized)
enum ManualCutTests {}

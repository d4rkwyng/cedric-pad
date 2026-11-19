import AppKit

/// CEDRIC_CHECK=multicaret (Scripts/tools-check.sh). Phase 0 stub: the
/// scaffolding is in place (Edit › Selection, all disabled). The
/// feature's subunit replaces this with the real check, driven by real
/// key and mouse events (plan-0.2.0.md §3, Tests).
@MainActor
extension DevChecks {
    static func multiCaretCheck(_ app: AppDelegate) {
        let tab = app.open(write("multicaret.txt", "one\ntwo\nthree\n"))!
        sized(tab)
        let up = String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!)
        run([
            sync {
                focus(tab)
                expectScaffold(app, #selector(AppDelegate.addNextOccurrenceMenu(_:)), "Edit › Selection › Add Next Occurrence", "d", [.command])
                expectScaffold(app, #selector(AppDelegate.selectAllOccurrencesMenu(_:)), "Edit › Selection › Select All Occurrences",
                               "g", [.control, .command])
                expectScaffold(app, #selector(AppDelegate.addCaretAboveMenu(_:)), "Edit › Selection › Add Caret Above", up, [.control, .shift])
                expectScaffold(app, #selector(AppDelegate.addCaretBelowMenu(_:)), "Edit › Selection › Add Caret Below", down, [.control, .shift])
                expectScaffold(app, #selector(AppDelegate.singleCaretMenu(_:)), "Edit › Selection › Single Caret")
            },
        ])
    }
}

import Foundation
import MacHIDApplication
import MacHIDDomain
import MacHIDQuartz
import MacHIDSystem

struct MacroSummary: Codable {
    let id: String
    let name: String
    let steps: Int
    let needsApproval: Bool
    let approved: Bool
}

/// Never prints what a macro does: only its name, size and approval state.
func summarize(_ macro: Macro) -> MacroSummary {
    let approved = !macro.needsApproval || macro.approvedFingerprint == MacroFingerprint.of(macro)
    return MacroSummary(id: macro.id, name: macro.name, steps: macro.steps.count, needsApproval: macro.needsApproval, approved: approved)
}

func refusalText(_ refusal: MacroRunner.Refusal) -> String {
    switch refusal {
    case .notApproved: "this macro runs commands, opens things or uses Shortcuts and has not been approved. The CLI never approves macros: review and approve it in the MacHID app."
    case .shellDisabled: "macros that run shell commands are turned off in MacHID settings"
    case .elevation: "the macro tries to gain administrator rights"
    case .tooManySteps: "the macro has too many steps"
    case .tooLong: "the macro waits too long in total"
    case .alreadyRunning: "the macro is already running"
    }
}

func runMacro(_ args: [String], options: GlobalOptions) async throws {
    guard let sub = args.first else { fail("macro needs list or run\n" + usage, code: ExitCode.usage) }
    let config = try await FileRemapRepository().load()

    switch sub {
    case "list":
        let summaries = config.macros.map(summarize)
        if options.json { printJSON(summaries); return }
        if summaries.isEmpty { print("No macros. Create them in the MacHID app."); return }
        for item in summaries {
            let state = item.needsApproval ? (item.approved ? "approved" : "NOT APPROVED") : "no approval needed"
            print("\(item.name)  [\(item.id)]  \(item.steps) steps  \(state)")
        }

    case "run":
        guard args.count == 2 else { fail("macro run needs <name>\n" + usage, code: ExitCode.usage) }
        guard let macro = config.macros.first(where: { matches(args[1], name: $0.name, id: $0.id) }) else {
            fail("no macro named '\(args[1])'. Run 'machid macro list'.")
        }
        // Refuse before anything else, so an unapproved macro is never started and nothing is asked of the system.
        if macro.needsApproval, macro.approvedFingerprint != MacroFingerprint.of(macro) {
            fail("refused: " + refusalText(.notApproved), code: ExitCode.refused)
        }
        let postsInput = macro.steps.contains { step in
            switch step {
            case .key, .text, .mouseClick: true
            default: false
            }
        }
        if postsInput, !RemapPermissions.accessibility {
            fail("this macro types or clicks, which needs the Accessibility permission for this terminal (System Settings > Privacy & Security > Accessibility)")
        }
        let runner = MacroRunner(poster: QuartzEventPoster(), shell: ProcessShellRunner(), launcher: WorkspaceLauncher(),
                                 log: FileMacroLog(), fingerprint: MacroFingerprint.of)
        switch await runner.run(macro, shellMacrosEnabled: config.shellMacrosEnabled) {
        case .completed: print("OK: macro '\(macro.name)' completed")
        case .refused(let why): fail("refused: " + refusalText(why), code: ExitCode.refused)
        case .failed(let why): fail("macro '\(macro.name)' failed: \(why)")
        case .cancelled: fail("macro '\(macro.name)' was cancelled")
        }

    default:
        fail("unknown macro command '\(sub)'\n" + usage, code: ExitCode.usage)
    }
}

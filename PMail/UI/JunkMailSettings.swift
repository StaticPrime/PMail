import PMailKit
import SwiftUI

/// Settings ▸ Junk Mail, in two tabs. Junk Mail: whether PMail filters junk and what it does with it (marks it, moves
/// it to the Junk folder, or does what's set up under Advanced), who's never taken for junk, and whether servers' own
/// junk marks count. Blocked: what happens to mail from blocked senders, whose lists are each account's own.
struct JunkMailSettingsPane: View {
    let app: AppModel
    @Bindable private var junk = JunkSettings.shared
    @State private var tab = Tab.junk
    @State private var editsRule = false
    @State private var confirmsReset = false
    @State private var learned = (junk: 0, good: 0)

    enum Tab { case junk, blocked }

    var body: some View {
        Form {
            Picker("Show", selection: $tab) {
                Text("Junk Mail").tag(Tab.junk)
                Text("Blocked").tag(Tab.blocked)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            switch tab {
            case .junk: junkSections
            case .blocked: blockedSections
            }
        }
        .settingsPane()
        .sheet(isPresented: $editsRule) {
            RuleEditor(rule: junk.policy.customRule, accounts: app.accounts.accounts) { junk.policy.customRule = $0 }
        }
        .alert("Reset what PMail has learned about junk mail?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                Task {
                    await junk.filter.reset()
                    await refreshLearned()
                    for session in app.accounts.sessions.values { await app.sync?.startLearning(session) }
                    await refreshLearned()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It forgets the junk and good mail it learned from, and starts again from each account’s inbox and spam folder.")
        }
        .task { await refreshLearned() }
        #if DEBUG
        // `-PMJunkTab blocked` shows the Blocked tab; `-PMJunkRule YES` opens Advanced.
        .onAppear {
            if UserDefaults.standard.string(forKey: "PMJunkTab") == "blocked" { tab = .blocked }
            if UserDefaults.standard.bool(forKey: "PMJunkRule") { editsRule = true }
        }
        #endif
    }

    @ViewBuilder private var junkSections: some View {
        let filters = junk.policy.filtersJunk
        let custom = junk.policy.junkAction == .custom
        Section {
            Toggle("Filter junk mail", isOn: $junk.policy.filtersJunk)
            Picker("When junk mail arrives:", selection: $junk.policy.junkAction) {
                Text("Mark it as junk, but leave it in the inbox").tag(JunkPolicy.JunkAction.mark)
                Text("Move it to the Junk or Spam folder").tag(JunkPolicy.JunkAction.moveToJunk)
                Text("Do what’s set up under Advanced").tag(JunkPolicy.JunkAction.custom)
            }
            .pickerStyle(.radioGroup)
            .disabled(!filters)
        }
        Section("Never junk") {
            Toggle("Mail from people in my contacts", isOn: $junk.policy.exemptsContacts)
            Toggle("Mail from people I’ve written to", isOn: $junk.policy.exemptsPreviousRecipients)
            Toggle("Mail addressed to me by my full name", isOn: $junk.policy.exemptsFullName)
            if custom {
                Text("Advanced has conditions of its own for this.").font(.pm(11.5)).foregroundStyle(.secondary)
            }
        }
        .disabled(!filters || custom)
        Section {
            Toggle("Trust the junk marks mail servers put in messages", isOn: $junk.policy.trustsServerMarks)
            Text("Some servers’ spam filters mark junk in a message’s headers instead of moving it. With this on, PMail takes their word for it.")
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
        .disabled(!filters)
        Section {
            HStack {
                Button("Reset…") { confirmsReset = true }
                Spacer()
                // Advanced is what junk gets when that's chosen above.
                Button("Advanced…") { editsRule = true }
                    .disabled(!filters || !custom)
                    .help(custom ? "Set up what happens to junk mail" : "Choose “Do what’s set up under Advanced” to set it up")
            }
            Text(learnedText).font(.pm(11.5)).foregroundStyle(.secondary)
        }
    }

    private var learnedText: String {
        let start = "PMail learns what junk looks like from mail you report as spam and mail you mark Not Junk, starting from each account’s inbox and spam folder."
        if learned.junk >= JunkFilter.minimumLearned, learned.good >= JunkFilter.minimumLearned {
            return start + " It has learned from \(learned.junk) junk and \(learned.good) good messages."
        }
        return start + " It has learned from \(learned.junk) junk and \(learned.good) good messages so far, and judges new mail once it has \(JunkFilter.minimumLearned) of each."
    }

    @ViewBuilder private var blockedSections: some View {
        Section {
            Toggle("Filter mail from blocked senders", isOn: $junk.policy.filtersBlocked)
            Picker("When mail from a blocked sender arrives:", selection: $junk.policy.blockedAction) {
                Text("Mark it as blocked, but leave it in the inbox").tag(JunkPolicy.BlockedAction.mark)
                Text("Move it to the Junk or Spam folder").tag(JunkPolicy.BlockedAction.moveToJunk)
                Text("Move it to the Trash").tag(JunkPolicy.BlockedAction.moveToTrash)
            }
            .pickerStyle(.radioGroup)
            .disabled(!junk.policy.filtersBlocked)
        }
        Section {
            Button("Manage Blocked Senders…") { SettingsWindowController.show(app, pane: .accounts) }
            Text("Report spam offers to block the sender, or everything from their domain. Each account keeps its own list, in Accounts.")
                .font(.pm(11.5)).foregroundStyle(.secondary)
        }
    }

    private func refreshLearned() async {
        let counts = await junk.filter.learnedCounts()
        learned = (counts.junk, counts.good)
    }
}

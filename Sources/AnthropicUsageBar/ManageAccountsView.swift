import SwiftUI

struct ManageAccountsView: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manage Accounts").font(.title2.weight(.semibold))

                Text("Each account keeps **its own login on file**, so they all stay independent — switching Claude Code / Conductor never changes what's shown here.\n\nTo add one: log into that account (in Claude Code or Conductor), then click **Add current login** — it captures whoever you're logged in as right now.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button { store.addCurrentLogin() } label: {
                    Label("Add current login", systemImage: "plus.circle.fill")
                }.buttonStyle(.borderedProminent)

                if store.accounts.isEmpty {
                    Text("No accounts yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.accounts) { acct in AccountRow(account: acct) }
                    }
                }
                Spacer()
            }
            .padding(20)
        }
    }
}

private struct AccountRow: View {
    @EnvironmentObject var store: AccountStore
    let account: ConfigAccount
    @State private var name: String = ""

    var body: some View {
        HStack {
            Image(systemName: store.hasCredential(account) ? "person.crop.circle.fill" : "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(store.hasCredential(account) ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 0) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { name = account.name }
                    .onSubmit { store.rename(account, to: name) }
                if let ident = store.identities[account.id] {
                    Text([ident.orgName, ident.email].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if !store.hasCredential(account) {
                    Text("no login saved — log into it, then Re-capture")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Re-capture") { store.recapture(account) }
                .buttonStyle(.borderless).font(.caption)
                .help("Save the account you're currently logged into, into this slot")
            Button(role: .destructive) { store.remove(account) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
    }
}

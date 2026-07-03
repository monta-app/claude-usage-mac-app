import SwiftUI

struct ManageAccountsView: View {
    @EnvironmentObject var store: AccountStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manage Accounts").font(.title2.weight(.semibold))

                Text("Register each Claude account once, then switch between them with one click — the app swaps the Claude Code login, so **Claude Code, Conductor, and other tools all use the account you pick**.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox("Add an account") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. **Log in** to the account (opens Terminal → browser).\n2. Back here, click **Add current login** to register it.\nRepeat for each account. Your current login is added the same way.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Log in…") { store.openLogin() }
                            Button("Add current login") { Task { await store.addCurrentLogin() } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(6)
                }

                if store.accounts.isEmpty {
                    Text("No accounts yet — log in and click *Add current login*.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(store.accounts) { acct in
                            HStack {
                                Image(systemName: acct.id == store.activeID ? "checkmark.circle.fill" : "person.crop.circle")
                                    .foregroundStyle(acct.id == store.activeID ? .green : .secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(acct.label).font(.subheadline)
                                    if acct.id == store.activeID {
                                        Text("active").font(.caption2).foregroundStyle(.green)
                                    }
                                }
                                Spacer()
                                if acct.id != store.activeID {
                                    Button("Switch to") { Task { await store.swap(to: acct) } }
                                        .font(.caption)
                                }
                                Button(role: .destructive) { store.remove(acct) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if let s = store.status {
                    Text(s).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(20)
        }
    }
}

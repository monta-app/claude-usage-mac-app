import SwiftUI

struct ManageAccountsView: View {
    @EnvironmentObject var store: AccountStore
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Manage Accounts").font(.title2.weight(.semibold))

                Text("See usage for several Claude accounts at once. **Default** is the account Claude Code and Conductor use. Each extra account logs in independently (its own config dir) — logging in never touches your default login or the Keychain.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(store.accounts) { acct in
                        AccountRow(account: acct)
                    }
                }

                GroupBox("Add another account") {
                    HStack {
                        TextField("Name (e.g. Work)", text: $newName)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            store.addAccount(name: newName.trimmingCharacters(in: .whitespaces)); newName = ""
                        }.buttonStyle(.borderedProminent)
                    }
                    .padding(6)
                }
                Text("After adding, click **Log in** on the new account and sign in as that Claude account.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

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
            Image(systemName: account.configDir == nil ? "person.crop.circle.fill" : "person.crop.circle")
                .foregroundStyle(account.configDir == nil ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 0) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { name = account.name }
                    .onSubmit { store.rename(account, to: name) }
                if let org = store.identities[account.id]?.orgName, !org.isEmpty {
                    Text([org, store.identities[account.id]?.email].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if account.id != AccountStore.defaultID {
                if !store.isIndependent(account) {
                    Text("mirrors default").font(.caption2).foregroundStyle(.orange)
                }
                Button("Use current login") { store.captureCurrent(account) }
                    .buttonStyle(.borderless).font(.caption)
                    .help("Snapshot whatever you're logged into right now as this account")
            }
            Button("Log in") { store.login(account) }.buttonStyle(.borderless).font(.caption)
            if account.id != AccountStore.defaultID {
                Button(role: .destructive) { store.remove(account) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
    }
}

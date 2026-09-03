import SwiftUI

/// entry to the server administration pages, shown to admin accounts only.
struct AdminScreen: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AdminUsersScreen()
                } label: {
                    Label("Users", systemImage: "person.2")
                }
                .accessibilityIdentifier("admin-users")

                NavigationLink {
                    AdminQueuesScreen()
                } label: {
                    Label("Job Queues", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("admin-queues")
            } footer: {
                Text("Manage the accounts and background jobs of your Immich server.")
            }
        }
        .navigationTitle("Administration")
        .navigationBarTitleDisplayMode(.inline)
    }
}

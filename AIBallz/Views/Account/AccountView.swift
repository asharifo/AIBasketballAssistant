import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var authManager: AuthManager

    var body: some View {
        Form {
            Section("User") {
                LabeledContent("ID", value: authManager.currentUser?.subject ?? "Unknown")
                LabeledContent("Name", value: authManager.currentUser?.name ?? "Not provided")
                LabeledContent("Email", value: authManager.currentUser?.email ?? "Not provided")
            }

            Section("Session") {
                Button("Log Out", role: .destructive) {
                    Task { await authManager.logout() }
                }
                .disabled(authManager.isBusy)

                if authManager.isBusy {
                    ProgressView("Logging out...")
                }
            }
        }
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        AccountView()
            .environmentObject(AuthManager())
    }
}

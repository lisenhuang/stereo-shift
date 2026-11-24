import StoreKit
import SwiftUI

struct VideoSubscriptionPaywallView: View {
    @ObservedObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
#if DEBUG
                    debugAccessSection
#endif
                    Text("Unlock StereoShift")
                        .font(.title2.bold())
                    Text("Unlock full-length video exports and save and share your photos and videos.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if subscriptionManager.isSubscribed {
                        Label("Subscription Active", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    purchaseSection(title: "One-Time Purchase", productID: SubscriptionManager.lifetimeVideoProductID)

                    purchaseSection(title: "Subscription", productID: SubscriptionManager.weeklyVideoProductID)

                    legalLinksSection
                }
                .padding(16)
            }
            .navigationTitle("Upgrade")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .task {
                await subscriptionManager.refreshProducts()
                await subscriptionManager.refreshEntitlements()
            }
            .alert(
                "Error",
                isPresented: Binding(
                    get: { subscriptionManager.errorMessage != nil },
                    set: { _ in subscriptionManager.clearError() }
                )
            ) {
                Button("OK", role: .cancel) {
                    subscriptionManager.clearError()
                }
            } message: {
                if let message = subscriptionManager.errorMessage {
                    Text(message)
                } else {
                    Text("Something went wrong.")
                }
            }
        }
    }

#if DEBUG
    private var debugAccessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if subscriptionManager.isDebugPaidAccessEnabled {
                Label("Debug paid access is active", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("debugPaidAccessActive")
            } else {
                Button {
                    subscriptionManager.enableDebugPaidAccessForSession()
                } label: {
                    Label("Debug: unlock paid access", systemImage: "hammer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("debugUnlockPaidAccess")
            }
            Text("Free for this session. Resets when the app restarts.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
#endif

    private func purchaseSection(title: LocalizedStringKey, productID: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if subscriptionManager.isLoadingProducts {
                ProgressView("Loading plans…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let product = subscriptionManager.products.first(where: { $0.id == productID }) {
                purchaseButton(for: product)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No subscription plans available right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Retry") {
                        Task {
                            await subscriptionManager.refreshProducts()
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func purchaseButton(for product: Product) -> some View {
        Button {
            Task {
                await subscriptionManager.purchase(product)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.headline)
                    Text(product.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if product.id == SubscriptionManager.weeklyVideoProductID {
                        Text("Billed weekly. Renews automatically until canceled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)

                Spacer()

                Text(product.displayPrice)
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(subscriptionManager.isPurchasing)
    }

    private var legalLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Restore Purchases") {
                Task {
                    await subscriptionManager.restorePurchases()
                }
            }
            .disabled(subscriptionManager.isPurchasing)

            Link("Privacy Policy", destination: AppLegalLinks.privacyPolicy)
            Link("Terms of Use (EULA)", destination: AppLegalLinks.termsOfUse)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

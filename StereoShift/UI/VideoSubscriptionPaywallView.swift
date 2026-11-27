import StoreKit
import SwiftUI

struct VideoSubscriptionPaywallView: View {
    @ObservedObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @State private var purchasingProductID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
#if DEBUG
                    debugAccessSection
#endif
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unlock StereoShift")
                            .font(.largeTitle.bold())
                        Text("Unlock full-length video exports and save and share your photos and videos.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

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
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Upgrade")
            .navigationBarTitleDisplayMode(.inline)
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
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

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
        let isWeekly = product.id == SubscriptionManager.weeklyVideoProductID
        let actionTitle: LocalizedStringKey = isWeekly ? "Subscribe Weekly" : "Buy Once"

        return Button {
            guard purchasingProductID == nil else { return }
            purchasingProductID = product.id
            Task {
                defer { purchasingProductID = nil }
                await subscriptionManager.purchase(product)
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.displayName)
                        .font(.title3.weight(.semibold))
                    Text(product.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if isWeekly {
                        Text("Billed weekly. Renews automatically until canceled.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    Text(actionTitle)
                    Spacer(minLength: 4)
                    if purchasingProductID == product.id {
                        ProgressView().tint(.white)
                    }
                    Text(product.displayPrice)
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(minHeight: 48)
                .background(Color(red: 0.15, green: 0.28, blue: 0.72), in: RoundedRectangle(cornerRadius: 12))
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(PurchaseCardStyle())
        .accessibilityIdentifier("purchase.\(product.id)")
        .disabled(subscriptionManager.isPurchasing || purchasingProductID != nil)
    }

    private var legalLinksSection: some View {
        VStack(spacing: 10) {
            Button {
                Task { await subscriptionManager.restorePurchases() }
            } label: {
                Label("Restore Purchases", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(subscriptionManager.isPurchasing || purchasingProductID != nil)

            HStack(spacing: 20) {
                Link("Privacy Policy", destination: AppLegalLinks.privacyPolicy)
                Link("Terms of Use (EULA)", destination: AppLegalLinks.termsOfUse)
            }
            .font(.footnote)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PurchaseCardStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.6)
    }
}

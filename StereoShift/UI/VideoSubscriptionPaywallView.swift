import StoreKit
import SwiftUI

struct VideoSubscriptionPaywallView: View {
    @ObservedObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Unlock StereoShift")
                        .font(.title2.bold())
                    Text("Unlock full-length video conversion, fullscreen previews, and saving and sharing photos and videos.")
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

import StoreKit
import SwiftUI

struct VideoSubscriptionPaywallView: View {
    @ObservedObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Unlock Video Conversion")
                        .font(.title2.bold())
                    Text("Video conversion and spatial video split to SBS are available to subscribers.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if subscriptionManager.isSubscribed {
                        Label("Subscription Active", systemImage: "checkmark.seal.fill")
                            .font(.headline)
                            .foregroundStyle(.green)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    subscriptionPlansSection

                    oneTimePurchaseSection

                    legalLinksSection
                }
                .padding(16)
            }
            .navigationTitle("Video Subscription")
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

    @ViewBuilder
    private var subscriptionPlansSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Subscription")
                .font(.headline)

            if #available(iOS 17.0, macOS 14.0, *) {
                SubscriptionStoreView(productIDs: [SubscriptionManager.weeklyVideoProductID])
                    .storeButton(.visible, for: .restorePurchases)
                    .storeButton(.visible, for: .policies)
                    .subscriptionStorePolicyDestination(url: AppLegalLinks.privacyPolicy, for: .privacyPolicy)
                    .subscriptionStorePolicyDestination(url: AppLegalLinks.termsOfUse, for: .termsOfService)
            } else {
                legacyPlansSection
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var oneTimePurchaseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-Time Purchase")
                .font(.headline)

            if subscriptionManager.isLoadingProducts {
                ProgressView("Loading plans…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let product = subscriptionManager.products.first(where: { $0.id == SubscriptionManager.lifetimeVideoProductID }) {
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
                                .multilineTextAlignment(.leading)
                        }

                        Spacer()

                        Text(product.displayPrice)
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(subscriptionManager.isPurchasing)
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

    private var legalLinksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link("Privacy Policy", destination: AppLegalLinks.privacyPolicy)
            Link("Terms of Use (EULA)", destination: AppLegalLinks.termsOfUse)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var legacyPlansSection: some View {
        if subscriptionManager.products.isEmpty {
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
        } else if let product = subscriptionManager.products.first(where: { $0.id == SubscriptionManager.weeklyVideoProductID }) {
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
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()

                    Text(product.displayPrice)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(subscriptionManager.isPurchasing)
        }
    }
}

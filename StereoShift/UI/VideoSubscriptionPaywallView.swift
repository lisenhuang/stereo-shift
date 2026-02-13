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

                    plansSection

                    Button {
                        Task {
                            await subscriptionManager.restorePurchases()
                        }
                    } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(subscriptionManager.isPurchasing)
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
    private var plansSection: some View {
        if subscriptionManager.isLoadingProducts {
            ProgressView("Loading plans…")
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if subscriptionManager.products.isEmpty {
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
        } else {
            VStack(spacing: 10) {
                ForEach(subscriptionManager.products, id: \.id) { product in
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
    }
}

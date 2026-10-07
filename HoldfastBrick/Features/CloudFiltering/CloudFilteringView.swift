import SwiftUI

/// Cloud Filtering (NextDNS): an optional extra layer with cloud-managed
/// blocklists and analytics.
struct CloudFilteringView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isToggling = false

    private var service: ServiceStatus? {
        appModel.overview?.services.first { $0.id == "nextdns" }
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: toggleBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cloud filtering").font(.headline)
                        Text("Extra protection managed by NextDNS")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isToggling || service?.installed != true)
            } footer: {
                if service?.installed == true {
                    Text("An optional second filter powered by NextDNS. Your Holdfast Brick already blocks ads on its own — turn this on if you also use NextDNS's cloud dashboard and settings.")
                } else {
                    Text("NextDNS isn't set up on your Holdfast Brick yet. It's optional — your device is protected without it.")
                }
            }

            if let detail = service?.detail, !detail.isEmpty {
                Section("Status") {
                    Text(detail.capitalized).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Cloud Filtering")
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { service?.running ?? false },
            set: { enabled in
                isToggling = true
                Task {
                    await appModel.perform { try await $0.setCloudFiltering(enabled: enabled) }
                    isToggling = false
                }
            }
        )
    }
}

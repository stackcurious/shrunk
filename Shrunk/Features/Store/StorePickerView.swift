import SwiftUI

struct StorePickerView: View {
    @StateObject private var vm = StorePickerViewModel()
    @Environment(\.dismiss) private var dismiss
    @AppStorage(StorePickerViewModel.storeNameKey) private var storeName: String = ""

    let embedded: Bool

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        Group {
            if embedded {
                storeList
            } else {
                NavigationStack {
                    storeList
                        .navigationTitle("Choose a store")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { dismiss() }
                                    .fontWeight(.semibold)
                            }
                        }
                }
            }
        }
    }

    private var storeList: some View {
        List {
            findSection
            if !storeName.isEmpty { selectedSection }
            resultSections
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    private var findSection: some View {
        Section {
            Button {
                Task { await vm.useCurrentLocation() }
            } label: {
                Label("Use Current Location", systemImage: "location.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(vm.state == .loading)

            HStack(spacing: 10) {
                TextField("City, neighborhood, store, or ZIP", text: $vm.query)
                    .textContentType(.location)
                    .submitLabel(.search)
                    .onSubmit { Task { await vm.search() } }
                    .accessibilityLabel("Search location")

                Button("Search") { Task { await vm.search() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canSearch || vm.state == .loading)
            }
        } header: {
            Text("Find nearby Kroger-family stores")
        } footer: {
            Text("Use your location once, or search by place. Shrunk saves only the store you choose.")
        }
    }

    private var selectedSection: some View {
        Section("Your store") {
            HStack(spacing: 12) {
                Text(storeName)
                Spacer(minLength: 8)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.verdictGoodDeep)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue("Selected")
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        switch vm.state {
        case .idle:
            Section {
                Text("Choose a store to add available shelf prices, promotions, stock, and unit costs to scans.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } footer: {
                attribution
            }
        case .loading:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Finding nearby stores…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityElement(children: .combine)
            }
        case .empty:
            Section {
                Text("No Kroger-family stores were found nearby. Try another city or ZIP.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } footer: {
                attribution
            }
        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(Color.shrunkRedDark)
            } footer: {
                attribution
            }
        case .loaded(let stores):
            Section {
                ForEach(Array(stores.enumerated()), id: \.element.id) { index, store in
                    Button { vm.select(store) } label: { row(store, isNearest: index == 0) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text(stores.first?.distanceMiles == nil ? "Nearby stores" : "Closest stores")
            } footer: {
                attribution
            }
        }
    }

    private var attribution: some View {
        Text(LivePrice.attribution)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    private func row(_ store: StoreLocation, isNearest: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(store.displayName)
                        .font(.body)
                    if isNearest, store.distanceMiles != nil {
                        Text("Nearest")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.verdictGoodDeep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.verdictGoodDeep.opacity(0.12), in: Capsule())
                    }
                }
                Text(store.addressLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let distance = store.distanceText {
                    Text(distance)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if vm.selectedId == store.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.verdictGoodDeep)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([store.displayName, store.addressLine, store.distanceText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(vm.selectedId == store.id ? "Selected" : "")
    }
}

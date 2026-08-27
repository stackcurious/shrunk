import SwiftUI

struct StorePickerView: View {
    @StateObject private var vm = StorePickerViewModel()
    @Environment(\.dismiss) private var dismiss

    /// Onboarding embeds the picker without navigation chrome.
    let embedded: Bool

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        if embedded {
            // No `NavigationStack` around this one, so `.searchable` has no bar
            // to live in — the ZIP gets a numeric field in its own section
            // instead, which is what a `Form` would do anyway.
            List {
                Section {
                    zipField
                }
                storeSections
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
        } else {
            NavigationStack {
                List {
                    storeSections
                }
                .listStyle(.insetGrouped)
                .searchable(text: $vm.zip, placement: .navigationBarDrawer(displayMode: .always),
                            prompt: "ZIP code")
                .onSubmit(of: .search) {
                    Task { await vm.search() }
                }
                .navigationTitle("Your store")
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

    // MARK: - ZIP entry (embedded only)

    private var zipField: some View {
        HStack(spacing: 12) {
            TextField("ZIP code", text: $vm.zip)
                .keyboardType(.numberPad)
                .monospacedDigit()
                .submitLabel(.search)
            Button("Find") { Task { await vm.search() } }
                .buttonStyle(.borderedProminent)
                .disabled(!vm.canSearch)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var storeSections: some View {
        switch vm.state {
        case .idle:
            Section {
                Text("Pick a Kroger store to see live prices and cost per ounce on every scan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } footer: {
                attribution
            }
        case .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        case .empty:
            Section {
                Text("No Kroger stores within 15 miles of that ZIP.")
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
                ForEach(stores) { store in
                    Button { vm.select(store) } label: { row(store) }
                        .buttonStyle(.plain)
                }
            } header: {
                Text("Nearby stores")
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

    private func row(_ store: StoreLocation) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName)
                    .font(.body)
                Text(store.addressLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if vm.selectedId == store.id {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.shrunkRed)
            }
        }
        .contentShape(Rectangle())
    }
}

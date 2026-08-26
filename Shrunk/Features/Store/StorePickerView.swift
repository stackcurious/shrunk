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
            picker
        } else {
            NavigationStack {
                picker
                    .navigationTitle("Your store")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { dismiss() }
                                .foregroundStyle(Color.shrunkRed)
                                .fontWeight(.semibold)
                        }
                    }
            }
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.md) {
                zipField
                results
                Text(LivePrice.attribution)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.smoke)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, ShrunkTheme.Spacing.sm)
            }
            .padding(.horizontal, ShrunkTheme.Spacing.lg)
            .padding(.vertical, ShrunkTheme.Spacing.md)
        }
        .background(Color.paper.ignoresSafeArea())
    }

    private var zipField: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
            Text("ZIP CODE").shrunkSectionLabel()
            HStack(spacing: ShrunkTheme.Spacing.sm) {
                TextField("45044", text: $vm.zip)
                    .keyboardType(.numberPad)
                    .font(.shrunkMonoBig)
                    .padding(.horizontal, ShrunkTheme.Spacing.md)
                    .padding(.vertical, 12)
                    .background(Color.mist)
                    .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
                Button("Find") { Task { await vm.search() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(vm.canSearch ? Color.shrunkRed : Color.smokeSoft)
                    .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))
                    .disabled(!vm.canSearch)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch vm.state {
        case .idle:
            Text("Pick a Kroger store to see live prices and cost per ounce on every scan.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
        case .loading:
            ProgressView().tint(Color.shrunkRed).frame(maxWidth: .infinity).padding(.vertical, ShrunkTheme.Spacing.lg)
        case .empty:
            Text("No Kroger stores within 15 miles of that ZIP.")
                .font(.shrunkBody)
                .foregroundStyle(Color.smoke)
        case .failed(let message):
            Text(message)
                .font(.shrunkBody)
                .foregroundStyle(Color.shrunkRedDark)
        case .loaded(let stores):
            VStack(spacing: 0) {
                ForEach(stores) { store in
                    Button { vm.select(store) } label: { row(store) }
                        .buttonStyle(.plain)
                }
            }
            .background(Color.surface)
            .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ShrunkTheme.Radius.lg, style: .continuous)
                    .stroke(Color.borderSoft, lineWidth: 0.5)
            )
        }
    }

    private func row(_ store: StoreLocation) -> some View {
        HStack(spacing: ShrunkTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(store.addressLine)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.smoke)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: vm.selectedId == store.id ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(vm.selectedId == store.id ? Color.shrunkRed : Color.smokeSoft)
        }
        .padding(.horizontal, ShrunkTheme.Spacing.md)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().fill(Color.borderSoft).frame(height: 0.5), alignment: .bottom)
    }
}

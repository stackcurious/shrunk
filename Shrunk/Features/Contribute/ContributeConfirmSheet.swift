import SwiftUI

/// Last stop before upload: the shopper checks (and can correct) what we read.
struct ContributeConfirmSheet: View {
    @ObservedObject var vm: ContributeViewModel
    let onRetake: () -> Void

    @FocusState private var quantityFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Check the size")
                    .font(.shrunkTitle)
                    .foregroundStyle(Color.ink)
                if vm.sourceLine.isEmpty {
                    Text("We couldn't read a net-content line. Type the size from the label.")
                        .font(.shrunkCallout)
                        .foregroundStyle(Color.smoke)
                } else {
                    Text("From the label: \(vm.sourceLine)")
                        .font(.shrunkMonoSmall)
                        .foregroundStyle(Color.smoke)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: ShrunkTheme.Spacing.sm) {
                Text("QUANTITY").shrunkSectionLabel()
                TextField("0", text: $vm.quantityText)
                    .keyboardType(.decimalPad)
                    .focused($quantityFocused)
                    .font(.shrunkMonoBig)
                    .foregroundStyle(Color.ink)
                    .padding(ShrunkTheme.Spacing.md)
                    .background(Color.mist)
                    .clipShape(RoundedRectangle(cornerRadius: ShrunkTheme.Radius.md, style: .continuous))

                Text("UNIT").shrunkSectionLabel()
                Picker("Unit", selection: $vm.unitKind) {
                    ForEach(UnitKind.allCases, id: \.self) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            Spacer(minLength: 0)

            VStack(spacing: ShrunkTheme.Spacing.sm) {
                ShrunkButton(
                    "Submit",
                    icon: "checkmark",
                    isLoading: vm.step == .submitting
                ) {
                    Task { await vm.submit() }
                }
                .disabled(!vm.canSubmit)

                ShrunkButton("Retake photo", icon: "arrow.counterclockwise", variant: .ghost, action: onRetake)
            }
        }
        .padding(ShrunkTheme.Spacing.lg)
        .background(Color.paper.ignoresSafeArea())
        .onAppear { quantityFocused = vm.quantityText.isEmpty }
    }
}

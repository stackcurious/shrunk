import SwiftUI

/// Last stop before upload: the shopper checks (and can correct) what we read.
struct ContributeConfirmSheet: View {
    @ObservedObject var vm: ContributeViewModel
    let onRetake: () -> Void

    @FocusState private var quantityFocused: Bool

    var body: some View {
        ScrollView {
            content
        }
        // Only scrolls when it has to, so at ordinary text sizes the sheet
        // still reads as a fixed card.
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear { quantityFocused = vm.quantityText.isEmpty }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check the size")
                    .font(.title2.bold())
                if vm.sourceLine.isEmpty {
                    Text("We couldn't read a net-content line. Type the size from the label.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("From the label: \(vm.sourceLine)")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Quantity")
                    .font(.headline)
                TextField("0", text: $vm.quantityText)
                    .keyboardType(.decimalPad)
                    .focused($quantityFocused)
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                    .padding(12)
                    .background(Color(.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text("Unit")
                    .font(.headline)
                    .padding(.top, 4)
                Picker("Unit", selection: $vm.unitKind) {
                    ForEach(UnitKind.allCases, id: \.self) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(spacing: 8) {
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
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

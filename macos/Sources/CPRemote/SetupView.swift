// The Setup sheet: the processor model and IP address, and a Test button
// that reports whether the processor chosen here answered at that address.

import CPx50Comms
import SwiftUI

struct SetupView: View {
    @ObservedObject var model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = SetupForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Setup")
                .font(.title2.bold())
            Picker("Processor", selection: $form.choice) {
                ForEach(RemoteModel.choices, id: \.self) { choice in
                    Text(RemoteModel.choiceName(choice)).tag(choice)
                }
            }
            LabeledContent("Processor IP") {
                TextField("192.168.1.50", text: $form.draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .accessibilityLabel("Processor IP address")
                    .onSubmit(saveAndConnect)
            }
            Text("Port \(form.choice.defaultPort)")
                .foregroundStyle(.secondary)
            HStack {
                Button("Test", action: runTest)
                    .disabled(form.testing)
                if form.testing { ProgressView().controlSize(.small) }
            }
            Text(form.testResult)
                .accessibilityLabel(form.testResult.isEmpty ? "" : "Test result: \(form.testResult)")
                .frame(minHeight: 20, alignment: .leading)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save and Connect", action: saveAndConnect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            form.draft = model.host
            form.choice = model.processorModel
        }
    }

    private func runTest() {
        form.testing = true
        form.testResult = "Testing…"
        Task {
            // The model picked in this sheet, saved or not.
            form.testResult = await model.test(address: form.draft, model: form.choice)
            form.testing = false
            // SwiftUI on macOS has no live region: say the result.
            AccessibilityNotification.Announcement(form.testResult).post()
        }
    }

    private func saveAndConnect() {
        model.host = form.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        model.choose(form.choice)
        dismiss()
        Task { await model.reconnect() }
    }
}

/// The sheet's editable fields. (A class, not `@State`: the Command Line
/// Tools ship no SwiftUI macro plugin, and `@State` is a macro.)
@MainActor
private final class SetupForm: ObservableObject {
    @Published var draft = ""
    @Published var choice: ProcessorModel = .cp650
    @Published var testResult = ""
    @Published var testing = false
}

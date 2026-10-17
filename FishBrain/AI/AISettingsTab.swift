import AppKit
import SwiftUI

/// Settings > AI: the two providers (a key each, checked, and a model), which one Generate uses, and the
/// defaults for a run.
struct AISettingsTab: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ai: AIAccountStore

    var body: some View {
        SettingsPage {
            SettingsHeading(text: "Provider")
            Text("Create with AI turns a PDF, a photo or your notes into cards. Add a key for the company you want to use, or use the model on this Mac, and choose which one makes the cards.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(AIProvider.cloud) { provider in
                ProviderCard(provider: provider)
            }
            OnDeviceCard()

            Text("Your files and prompt are sent to Anthropic or OpenAI if you pick them, and billed to your API key, separately from any ChatGPT or Claude subscription. Apple Intelligence keeps everything on this Mac. Make a key at \(AIProvider.anthropic.keysPage) or \(AIProvider.openAI.keysPage).")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Prices come from a built-in list, not from the providers, so say how old it is.
            Text(AIPricing.footnote())
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(AIPricing.tooltip())

            if let problem = ai.storageProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Status.problem)
            }

            HairlineDivider().padding(.vertical, 6)

            SettingsHeading(text: "Defaults")
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cards per run")
                        .font(Theme.Typography.rowTitle)
                        .foregroundStyle(Theme.TextColor.primary)
                    Text("How many cards Create with AI asks for to start with. You can change it each time.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Picker("Cards per run", selection: $settings.ai.cardsPerRun) {
                    ForEach(CardsPerRun.choices(including: settings.ai.cardsPerRun), id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Cards per run")
            }
            SettingToggleRow(
                title: "Show an estimated cost before generating",
                detail: "Worked out from how much you are sending and the price list above, so it is only an estimate. For Anthropic, what you have added is sent to Anthropic to be counted before you press Generate; turn this off to send nothing until then.",
                isOn: $settings.ai.showsCostEstimate
            )
        }
        // When Settings opens: ask again for model lists older than a day, and whether Apple Intelligence is ready.
        .task { await ai.refreshStaleModels() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in ai.refreshOnDevice() }
    }
}

enum CardsPerRun {
    /// The offered counts, plus the saved one if it isn't among them.
    static func choices(including current: Int) -> [Int] {
        (AISettings.cardsPerRunChoices + [current]).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }.sorted()
    }
}

/// Apple Intelligence: the model that comes with the Mac. No key, no price, and nothing leaves the Mac.
private struct OnDeviceCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ai: AIAccountStore

    private var status: OnDeviceStatus { ai.onDevice }
    private var isDefault: Bool { settings.ai.provider == .appleIntelligence }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { ai.setDefaultProvider(.appleIntelligence) } label: {
                    Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(status.isAvailable ? Theme.TextColor.primary : Theme.TextColor.secondary)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .disabled(!status.isAvailable)
                .help(status.isAvailable ? "Use Apple Intelligence to make cards" : (status.detail ?? "Not available on this Mac"))
                .accessibilityLabel("Use Apple Intelligence")
                .accessibilityAddTraits(isDefault ? .isSelected : [])

                Text("Apple Intelligence (on device)")
                    .font(Theme.Typography.rowTitle.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.primary)
                if isDefault {
                    Text("In use")
                        .font(Theme.Typography.micro.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.secondary)
                }
                Spacer(minLength: 8)
                Text(status.isAvailable ? "✓ \(status.headline)" : status.headline)
                    .font(Theme.Typography.footnote.weight(status.isAvailable ? .semibold : .regular))
                    .foregroundStyle(status.isAvailable ? Theme.Status.ok : Theme.TextColor.secondary)
            }
            Text("Free and private: nothing leaves your Mac, and no key is needed. It is a smaller model than Claude or GPT, and reads text and PDFs that have selectable text\(status.supportsImages ? ", and pictures" : "").")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = status.detail {
                Text(detail)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.isAvailable {
                Text("It reads about \(ComposerFormat.words(OnDeviceChunker.materialCharacters(contextSize: status.contextSize) / 6)) at a time, so longer material is cut into parts, and a very long one is cut short.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Apple Intelligence, on device")
    }
}

/// One provider: whether it is the one used, its key, how that is doing, and its model.
private struct ProviderCard: View {
    var provider: AIProvider

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var ai: AIAccountStore
    @State private var draftKey = ""

    private var hasKey: Bool { ai.hasKey(provider) }
    private var isDefault: Bool { settings.ai.provider == provider }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            keyRow
            if hasKey { modelSection }
            if let notice = ai.notices[provider] {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.TextColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("OK") { ai.dismissNotice(for: provider) }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.TextColor.primary)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous).fill(Theme.TextColor.primary.with(opacity: 0.05)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(provider.displayName)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { ai.setDefaultProvider(provider) } label: {
                Image(systemName: isDefault ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(hasKey ? Theme.TextColor.primary : Theme.TextColor.secondary)
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .disabled(!hasKey)
            .help(hasKey ? "Use \(provider.displayName) to make cards" : "Add a key to use \(provider.displayName)")
            .accessibilityLabel("Use \(provider.displayName)")
            .accessibilityAddTraits(isDefault ? .isSelected : [])

            Text(provider.displayName)
                .font(Theme.Typography.rowTitle.weight(.semibold))
                .foregroundStyle(Theme.TextColor.primary)
            if isDefault {
                Text("In use")
                    .font(Theme.Typography.micro.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            Spacer(minLength: 8)
            StatusView(status: ai.status(for: provider))
        }
    }

    // MARK: Key

    @ViewBuilder
    private var keyRow: some View {
        if let masked = ai.maskedKey(for: provider) {
            HStack(spacing: 8) {
                Text(masked)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.TextColor.cardBack)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.Surface.control))
                    .accessibilityLabel("Key, ends in \(masked.suffix(4))")
                Spacer(minLength: 8)
                Button("Remove") { ai.removeKey(for: provider) }
                    .buttonStyle(.capsuleSecondary)
                    .accessibilityLabel("Remove the \(provider.displayName) key")
            }
        } else {
            HStack(spacing: 8) {
                SecureField("Paste a key (\(provider.keyHint))", text: $draftKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    // A pasted key is long and arrives all at once: check it straight away.
                    .onChange(of: draftKey) { old, new in
                        if new.count >= 20, new.count - old.count > 8 { save() }
                    }
                    .accessibilityLabel("\(provider.displayName) API key")
                Button("Add Key", action: save)
                    .buttonStyle(.capsulePrimary)
                    .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        let key = draftKey
        draftKey = ""
        Task { await ai.saveKey(key, for: provider) }
    }

    // MARK: Model

    private var modelSection: some View {
        let visible = ai.visibleModels(for: provider)
        let selected = settings.ai.model(for: provider)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Model")
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(Theme.TextColor.secondary)
                Menu {
                    ForEach(visible) { model in
                        Button { ai.selectModel(model.id, for: provider) } label: {
                            if model.id == selected {
                                Label(model.pickerTitle, systemImage: "checkmark")
                            } else {
                                Text(model.pickerTitle)
                            }
                        }
                    }
                } label: {
                    Text(ai.selectedModel(for: provider)?.displayName ?? selected ?? "Choose a model")
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(visible.isEmpty)
                .accessibilityLabel("\(provider.displayName) model")

                Spacer(minLength: 8)
                Button { Task { await ai.refreshModels(for: provider) } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(Theme.Typography.footnote)
                        .accessibilityHidden(true)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.TextColor.secondary)
                .disabled(ai.status(for: provider) == .checking)
                .help("Ask \(provider.displayName) for the models this key can use")
                .accessibilityLabel("Refresh the \(provider.displayName) models")
            }

            if let selected {
                Text(AIPricing.priceLine(for: selected))
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(AIPricing.tooltip())
            }
            if let model = ai.selectedModel(for: provider), model.isTextAndPDFOnly {
                Text("This model reads text and PDFs, not pictures.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
            if provider == .openAI {
                Toggle("Show all models", isOn: $settings.ai.showsAllOpenAIModels)
                    .toggleStyle(.checkbox)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
                    .help("OpenAI's list also has models for audio, images and search. By default only likely chat models show.")
            }
        }
    }
}

/// "✓ Works", "Checking…", or what went wrong.
private struct StatusView: View {
    var status: AIAccountStore.KeyStatus

    var body: some View {
        switch status {
        case .noKey:
            Text("No key")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
        case .saved:
            Text("Key saved")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.TextColor.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.TextColor.secondary)
            }
        case .works:
            Text("✓ Works")
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.Status.ok)
        case .failed(let error):
            Text(error.message)
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.Status.problem)
                .multilineTextAlignment(.trailing)
        }
    }
}

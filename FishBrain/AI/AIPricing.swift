import Foundation

/// What a model costs per million tokens, in US dollars.
struct ModelPrice: Equatable, Sendable {
    var inputPerMillion: Double
    var outputPerMillion: Double

    func cost(inputTokens: Int, outputTokens: Int) -> Double {
        Double(inputTokens) / 1_000_000 * inputPerMillion + Double(outputTokens) / 1_000_000 * outputPerMillion
    }
}

/// Prices FishBrain shows, and the one place their wording lives. Neither provider's model list says what
/// a model costs, so these come from a built-in table that is checked by hand. **Whoever changes a price
/// updates `lastUpdated` in the same commit.** Everything shown from here says it is an estimate and when
/// the prices were last updated, because they may have changed since.
enum AIPricing {
    /// When the table below was last checked.
    static let lastUpdated: Date = {
        var parts = DateComponents()
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = TimeZone(identifier: "UTC")
        parts.year = 2026; parts.month = 10; parts.day = 8; parts.hour = 12
        return parts.date!
    }()

    /// Per million tokens, input then output.
    static let table: [String: ModelPrice] = [
        // Anthropic
        "claude-opus-5-5": ModelPrice(inputPerMillion: 4, outputPerMillion: 20),
        "claude-opus-5": ModelPrice(inputPerMillion: 5, outputPerMillion: 25),
        "claude-opus-4-8": ModelPrice(inputPerMillion: 5, outputPerMillion: 25),
        "claude-sonnet-5-5": ModelPrice(inputPerMillion: 2, outputPerMillion: 10),
        "claude-sonnet-5": ModelPrice(inputPerMillion: 2, outputPerMillion: 10),
        "claude-haiku-5-5": ModelPrice(inputPerMillion: 0.10, outputPerMillion: 0.50),
        "claude-fable-5-1": ModelPrice(inputPerMillion: 10, outputPerMillion: 50),
        // OpenAI
        "gpt-6-astra": ModelPrice(inputPerMillion: 10, outputPerMillion: 50),
        "gpt-6.1-sol": ModelPrice(inputPerMillion: 2, outputPerMillion: 10),
        "gpt-6-luna": ModelPrice(inputPerMillion: 0.10, outputPerMillion: 0.50),
    ]

    static func price(for modelID: String) -> ModelPrice? { table[modelID] }

    // MARK: Words

    /// "$4", "$0.10", "$20".
    static func dollars(_ value: Double) -> String {
        value == value.rounded() ? "$\(Int(value))" : String(format: "$%.2f", value)
    }

    /// "8 Oct 2026" (the order and the month's name follow the person's language and region).
    static func updatedText(locale: Locale = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC")!)
        return lastUpdated.formatted(style)
    }

    /// "(estimate · prices updated 8 Oct 2026)": the note every price and cost carries.
    static func estimateNote(locale: Locale = .current) -> String {
        "(estimate · prices updated \(updatedText(locale: locale)))"
    }

    /// A model's price: "$4 / $20 per million tokens (estimate · prices updated 8 Oct 2026)", or
    /// "price not known" for a model that isn't in the table.
    static func priceLine(for modelID: String, locale: Locale = .current) -> String {
        guard let price = price(for: modelID) else { return "price not known" }
        return "\(dollars(price.inputPerMillion)) / \(dollars(price.outputPerMillion)) per million tokens \(estimateNote(locale: locale))"
    }

    /// What a run costs: "about $0.25 (estimate · prices updated 8 Oct 2026)", before it (worked out from the
    /// size of what is sent) and after it (from the tokens used). Neither is the bill.
    static func costLine(_ cost: Double, locale: Locale = .current) -> String {
        let amount = cost < 0.005 ? "less than $0.01" : "about " + String(format: "$%.2f", cost)
        return "\(amount) \(estimateNote(locale: locale))"
    }

    /// A cost that could be anywhere between two amounts: "about $0.20–$0.30 (estimate · prices updated
    /// 8 Oct 2026)". Says the one amount when both round to the same cent.
    static func costRangeLine(_ low: Double, _ high: Double, locale: Locale = .current) -> String {
        let lowText = String(format: "$%.2f", low), highText = String(format: "$%.2f", high)
        guard high >= 0.005, lowText != highText else { return costLine(high, locale: locale) }
        return "about \(lowText)–\(highText) \(estimateNote(locale: locale))"
    }

    /// The line under the model pickers, once.
    static func footnote(locale: Locale = .current) -> String {
        "Prices last updated \(updatedText(locale: locale)) and may have changed since. Your provider's pricing page has the current rates (\(AIProvider.anthropic.pricingPage), \(AIProvider.openAI.pricingPage))."
    }

    /// The tooltip on any price or cost.
    static func tooltip(locale: Locale = .current) -> String {
        "Worked out from FishBrain's price list, last updated \(updatedText(locale: locale)). Your provider's billing page shows what you were actually charged."
    }
}

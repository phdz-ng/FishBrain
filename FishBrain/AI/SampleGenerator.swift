#if DEBUG
import Foundation

/// A pretend provider for Debug builds (`-FishBrainSampleAI`): it writes a made-up deck, a card at a time,
/// and answers a refine or a rewrite, so Create with AI can be tried without a key. Nothing goes online.
struct SampleGenerator: CardGenerator {
    /// How long each card takes to arrive.
    var delay: Duration = .milliseconds(700)

    static let cards: [GeneratedCard] = [
        ("What is the net ATP yield of glycolysis per glucose?", "2 ATP (4 produced, 2 invested)", 166),
        ("Where in the cell does glycolysis happen?", "In the cytosol", 165),
        ("What does pyruvate oxidation produce from one pyruvate?", "Acetyl CoA, 1 NADH and 1 CO₂", 168),
        ("How many turns of the citric acid cycle per glucose?", "Two, one for each acetyl CoA", 169),
        ("Which enzyme is the key control point of glycolysis?", "Phosphofructokinase (PFK), inhibited by ATP", 177),
        ("How many NADH does one turn of the citric acid cycle make?", "3 NADH (plus 1 FADH₂ and 1 ATP)", 171),
        ("What is substrate-level phosphorylation?", "Making ATP by moving a phosphate from a substrate straight to ADP", 166),
        ("Where does the citric acid cycle happen?", "In the mitochondrial matrix", 169),
        ("What is the final electron acceptor of the electron transport chain?", "Oxygen", 172),
        ("What is made when NAD⁺ takes electrons?", "NADH", 164),
        ("What does the enzyme ATP synthase do?", "Makes ATP from ADP and phosphate as protons flow through it", 174),
        ("How many ATP does one glucose give in total?", "About 30 to 32", 175),
    ].map { GeneratedCard(front: $0.0, back: $0.1, sourcePage: $0.2) }

    func generate(_ request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                let usage = GenerationUsage(inputTokens: 52_000, outputTokens: 1_200)
                switch request.task {
                case .create:
                    continuation.yield(.deckName("Cellular Respiration: Glycolysis & Krebs"))
                    for index in 0..<request.cardCount {
                        try? await Task.sleep(for: delay)
                        if Task.isCancelled { break }
                        var card = Self.cards[index % Self.cards.count]
                        if index >= Self.cards.count { card.front += " (\(index / Self.cards.count + 1))" }
                        continuation.yield(.card(card))
                    }
                case .refine(_, let deckName, let current):
                    continuation.yield(.deckName(deckName))
                    try? await Task.sleep(for: .seconds(1))
                    for card in current {
                        let shorter = card.editedByPerson == true ? card.back : String(card.back.split(separator: " ").prefix(4).joined(separator: " "))
                        continuation.yield(.card(GeneratedCard(front: card.front, back: shorter, sourcePage: card.sourcePage)))
                    }
                    continuation.yield(.card(GeneratedCard(front: "What is the Krebs cycle's other name?", back: "The citric acid cycle", sourcePage: 169)))
                case .replace(let card, let deckName):
                    continuation.yield(.deckName(deckName))
                    try? await Task.sleep(for: .seconds(1))
                    continuation.yield(.card(GeneratedCard(front: "Rewritten: " + card.front, back: card.back, sourcePage: card.sourcePage)))
                }
                continuation.yield(.finished(usage))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

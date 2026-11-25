import Foundation
import Testing

@testable import Bol

@Suite struct EffortTests {
	@Test func neverOffersLessThanMedium() {
		#expect(AgentEffort.allCases.first == .medium)
		#expect(Config().agentEffort == .medium)
	}

	@Test func aSavedLowEffortReadsAsMedium() throws {
		let saved = try JSONDecoder().decode([String: AgentEffort].self, from: Data(#"{"effort":"low"}"#.utf8))
		#expect(saved["effort"] == .medium)
		let kept = try JSONDecoder().decode([String: AgentEffort].self, from: Data(#"{"effort":"high"}"#.utf8))
		#expect(kept["effort"] == .high)
	}
}

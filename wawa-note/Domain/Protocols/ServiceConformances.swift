import Foundation
import SwiftData

// Related JIRA: KAN-11, KAN-56

// MARK: - Protocol Conformances
//
// Each service already implements the required methods with compatible signatures.
// These extensions declare conformance — no additional implementation needed.
// Swift automatically matches methods with default parameters to protocol requirements.

extension ProjectService: ProjectServiceProtocol {}
extension KnowledgeItemService: KnowledgeItemServiceProtocol {}
extension ProjectDerivedItemService: ProjectDerivedItemServiceProtocol {}
extension GraphEdgeService: GraphEdgeServiceProtocol {}
extension PersonService: PersonServiceProtocol {}
extension EntityService: EntityServiceProtocol {}

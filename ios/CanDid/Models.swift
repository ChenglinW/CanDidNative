import Foundation

enum Scenario: String, CaseIterable, Codable, Identifiable {
    case interview, pitch, academic, sales
    var id: String { rawValue }
    var title: String { switch self { case .interview: return "面试"; case .pitch: return "路演"; case .academic: return "学术报告"; case .sales: return "客户沟通" } }
}
struct BodyText: Codable { var text: String }
struct Evidence: Codable, Hashable { var session_id: String; var start_ms: Int; var end_ms: Int }
struct Asset: Codable, Identifiable {
    var id: String; var title: String; var body: BodyText; var kind: String
    var scenario: String?; var status: String; var trust: String; var version: Int
    var tags: [String]; var producer: String?; var rubric_version: String?
    var evidence_refs: [Evidence]?; var confirmed_at: String?; var source_session_id: String?
    var isFact: Bool { trust == "L3_confirmed" }
}
struct OccasionFields: Codable { var tags: [String]?; var goal: String? }
struct Occasion: Codable, Identifiable {
    var id: String; var scenario: String; var title: String; var status: String
    var fields: OccasionFields; var template_version: String?
}
struct Segment: Codable, Identifiable {
    var id: String; var session_id: String; var speaker: String
    var start_ms: Int; var end_ms: Int; var text: String
}
struct Session: Codable, Identifiable {
    var id: String; var occasion_id: String?; var scenario: String; var kind: String
    var consent: String; var pipeline_status: String; var duration_ms: Int
    var retention_days: Int; var audio_purged_at: String?; var started_at: String?
    var fixture: Bool?; var rubric_version: String; var transcript_segments: [Segment]?
    var local_audio: String?; var pipeline_error: String?
    var recording_source: String?; var device_file_id: Int?
    var pipeline_error_message: String?; var llm_model: String?
}
struct Capabilities: Decodable { var llm_configured: Bool; var llm_provider: String; var llm_model: String; var asr_configured: Bool }
struct Diagnosis: Codable, Identifiable {
    var id: String; var session_id: String; var dimension: String; var finding: String
    var suggestion: String; var evidence_refs: [Evidence]; var rubric_version: String; var producer: String
}
struct Review: Codable { var session: Session; var diagnoses: [Diagnosis]; var draft_assets: [Asset]; var audio_note: String? }
struct ContextItem: Codable, Identifiable { var trust: String; var ref: String; var text: String; var id: String { ref } }
struct ContextSection: Codable, Identifiable { var key: String; var items: [ContextItem]; var id: String { key } }
struct ContextPack: Codable { var purpose: String; var sections: [ContextSection]; var token_count: Int; var truncated: [String] }
struct Weakness: Codable, Identifiable { var id: String; var description: String; var state: String; var user_disagrees: Bool }
struct ProgressPack: Codable { var status: String; var n_sessions: Int; var rubric_version: String; var weaknesses: [Weakness] }
struct Page<T: Decodable>: Decodable { var data: [T]; var next_cursor: String? }
struct Link: Decodable { var url: String?; var upload_url: String? }
struct MediaReceipt: Codable { var storage_path: String; var sha256: String; var mime: String; var bytes: Int }
struct APIError: Decodable { var error: APIErrorDetail }
struct APIErrorDetail: Decodable { var code: String; var message: String }
struct LocalSnapshot: Codable { var assets: [Asset]; var occasions: [Occasion]; var sessions: [Session]; var diagnoses: [Diagnosis]; var onboarding: Bool }
enum PrototypeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

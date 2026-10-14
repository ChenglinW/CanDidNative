import Foundation
import UserNotifications
import CryptoKit

struct ProductParticipant:Codable,Hashable {var name:String;var role:String;var side:String}
struct ProductProject:Codable,Identifiable {
    var id:String;var name:String;var goal:String;var default_thread_id:String;var version:Int;var status:String
    var scenario:String?;var organization:String?;var opportunity:String?;var stage:String?;var participants:[ProductParticipant]?;var result:String?;var is_example:Bool?
    var scenarioTitle:String {scenario=="sales" ? "销售 BD":scenario=="interview" ? "面试":"待分类"}
    var stageTitle:String {ProductLabels.stage(stage ?? "")}
}
struct BusinessMeeting:Codable,Identifiable {
    var id:String;var project_id:String;var title:String;var goal:String;var status:String;var version:Int
    var scheduled_at:String?;var actual_at:String?;var kind:String?;var timezone:String?;var is_practice:Bool?;var is_example:Bool?
    var date:Date? {ProductDate.parse(scheduled_at ?? actual_at ?? "")}
}
struct ProductEvidence:Codable,Hashable,Identifiable {
    var source_id:String;var source_version:String?;var session_id:String?;var start_ms:Int?;var end_ms:Int?;var quote:String?
    var id:String {source_id}
}
struct ProjectItem:Codable,Identifiable {
    var id:String;var project_id:String;var meeting_id:String?;var kind:String;var text:String;var owner:String;var due_at:String?;var status:String;var version:Int
    var external_safe:Bool;var evidence_refs:[ProductEvidence];var reference_status:String?;var question_key:String?;var is_practice:Bool?;var is_example:Bool?
    var current:Bool {reference_status != "superseded"}
}
struct PreparationSection:Codable,Identifiable {var title:String;var text:String;var evidence_refs:[ProductEvidence];var suggestion:Bool?;var id:String {title+text}}
struct PreparationPack:Codable,Identifiable {var id:String;var meeting_id:String;var project_id:String;var sections:[PreparationSection]}
struct FollowupDraft:Codable,Identifiable {
    var id:String;var meeting_id:String;var project_id:String;var channel:String;var `internal`:Bool;var title:String;var text:String;var version:Int;var send_status:String;var recipient:String;var evidence_refs:[ProductEvidence]
}
struct RecordingAssociation:Codable,Identifiable {var id:String;var meeting_id:String;var project_id:String;var session_id:String;var active:Bool}
struct ProjectQuestion:Codable,Identifiable {var key:String;var status:String;var occurrences:Int;var wording_variants:Int;var questions:[ProjectItem];var answers:[ProjectItem];var id:String{key}}
struct ProductDetail:Codable {var tracking:[ProjectQuestion]?=nil;var project:ProductProject;var meetings:[BusinessMeeting];var items:[ProjectItem];var preparations:[PreparationPack];var followups:[FollowupDraft];var recordings:[RecordingAssociation]}
struct PersonalDiscovery:Codable,Identifiable {var id:String;var title:String;var text:String;var status:String;var version:Int;var evidence_refs:[ProductEvidence];var reference_status:String?}
struct PersonalProgress:Decodable {var sample_count:Int;var note:String;var metrics:[ProgressMetric]}
struct ProgressMetric:Decodable {var name:String;var count:Int;var total:Int;var evidence_refs:[ProductEvidence]}
struct ProductExport:Decodable {var title:String;var text:String;var `internal`:Bool}
struct NaturalProductResult:Decodable {var project:ProductProject;var meeting:BusinessMeeting?}
enum ProductDate {
    static func parse(_ value:String)->Date? {let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return formatter.date(from:value) ?? ISO8601DateFormatter().date(from:value)}
    static func display(_ value:String?)->String {value.flatMap(parse)?.formatted(date:.abbreviated,time:.shortened) ?? "时间待定"}
}
enum ProductLabels {
    static let sales=["demand","proposal","negotiation","won","lost"]
    static let interview=["preparing","hr","business","final","offer","closed"]
    static func stage(_ s:String)->String { ["demand":"需求","proposal":"方案","negotiation":"谈判","won":"成交","lost":"未成交","preparing":"准备中","hr":"HR 面","business":"业务面","final":"终面","offer":"已获 Offer","closed":"已结束"][s] ?? "待完善" }
    static func kind(_ s:String)->String {["consensus":"共识","question":"问题","answer":"回答","commitment":"承诺","action":"行动","internal":"内部进展","gap":"资料缺口","story":"已讲故事","weakness":"待练问题"][s] ?? s}
}
struct ProductCache:Codable {var ownerTokenFingerprint:String?=nil;var projects:[ProductProject];var details:[ProductDetail];var discoveries:[PersonalDiscovery]}
@MainActor final class ProductNotifications {
    static let shared=ProductNotifications()
    private let center=UNUserNotificationCenter.current()
    func authorize() async { _=try? await center.requestAuthorization(options:[.alert,.sound,.badge]) }
    func sync(_ items:[ProjectItem]) async {
        guard !ProcessInfo.processInfo.arguments.contains("-candid-ui-testing") else{return}
        let old=await center.pendingNotificationRequests().filter{$0.identifier.hasPrefix("candid-action-")}
        let current=items.filter{$0.kind=="action" && $0.status=="open" && $0.current && $0.is_practice != true && $0.is_example != true}
        let desired=Set(current.compactMap { item in ProductDate.parse(item.due_at ?? "").map{_ in "candid-action-"+item.id} })
        center.removePendingNotificationRequests(withIdentifiers:old.map(\.identifier).filter{!desired.contains($0)})
        guard await center.notificationSettings().authorizationStatus == .authorized else{return}
        for item in current {
            guard let date=ProductDate.parse(item.due_at ?? ""),date>Date() else{center.removePendingNotificationRequests(withIdentifiers:["candid-action-"+item.id]);continue}
            let content=UNMutableNotificationContent();content.title="核对一下跟进";content.body=item.text;content.sound = .default
            let trigger=UNCalendarNotificationTrigger(dateMatching:Calendar.current.dateComponents([.year,.month,.day,.hour,.minute],from:date),repeats:false)
            try? await center.add(UNNotificationRequest(identifier:"candid-action-"+item.id,content:content,trigger:trigger))
        }
    }
}
extension Store {
    func reloadProducts() async throws {
        guard remote else{seedProducts();return}
        let connection=api
        let identity=DeviceRecordingMap.identity(connection)
        let rows:[ProductProject]=try await connection.all("/v1/projects")
        var details:[ProductDetail]=[]
        for p in rows {details.append(try await connection.call("/v1/projects/"+p.id))}
        let discoveries:[PersonalDiscovery]=try await connection.all("/v1/discoveries")
        guard identity==DeviceRecordingMap.identity(api),remote,!Task.isCancelled else{throw CancellationError()}
        products=rows;productDetails=details;personalDiscoveries=discoveries
        let cache=ProductCache(ownerTokenFingerprint:productOwnerFingerprint,projects:rows,details:details,discoveries:discoveries)
        let url=productCacheURL
        try? JSONEncoder().encode(cache).write(to:url,options:[.atomic,.completeFileProtection])
        await ProductNotifications.shared.sync(details.flatMap(\.items))
    }
    var productOwnerFingerprint:String {SHA256.hash(data:Data(TokenVault.read().utf8)).map{String(format:"%02x",$0)}.joined()}
    var productCacheURL:URL {demoURL.deletingLastPathComponent().appendingPathComponent("product-"+base.data(using:.utf8)!.base64EncodedString().replacingOccurrences(of:"/",with:"_").prefix(80)+".json")}
    func loadProductCache() {
        if let data=try? Data(contentsOf:productCacheURL),let cache=try? JSONDecoder().decode(ProductCache.self,from:data),cache.ownerTokenFingerprint==productOwnerFingerprint {
            products=cache.projects;productDetails=cache.details;personalDiscoveries=cache.discoveries
        }
    }
    func seedProducts() {
        guard !remote else{return}
        products=occasions.map{ o in ProductProject(id:o.id,name:o.title,goal:o.fields.goal ?? "",default_thread_id:"",version:1,status:o.status,scenario:o.scenario,organization:"",opportunity:"",stage:o.scenario=="sales" ? "demand":"preparing",participants:[],result:nil,is_example:true) }
        let interview=ProductProject(id:"demo-interview",name:"示例 · 产品经理面试",goal:"准备业务面",default_thread_id:"",version:1,status:"active",scenario:"interview",organization:"示例公司",opportunity:"产品经理",stage:"business",participants:[],result:nil,is_example:true)
        products.append(interview)
        productDetails=products.map { p in
            let meetings=sessions.filter{$0.occasion_id==p.id}.map { s in BusinessMeeting(id:s.id,project_id:p.id,title:"示例 · 第一场沟通",goal:p.goal,status:"completed",version:1,scheduled_at:nil,actual_at:s.started_at,kind:s.kind,timezone:"Asia/Hong_Kong",is_practice:true,is_example:true) }
            var timeline=meetings
            var components=Calendar.current.dateComponents([.year,.month,.day],from:Date().addingTimeInterval(86400));components.hour=14
            let date=Calendar.current.date(from:components) ?? Date()
            timeline.append(BusinessMeeting(id:"demo-next-"+p.id,project_id:p.id,title:p.scenario=="interview" ? "示例 · 业务面":"示例 · 下一场谈判",goal:p.goal,status:"planned",version:1,scheduled_at:ISO8601DateFormatter().string(from:date),actual_at:nil,kind:"communication",timezone:"Asia/Hong_Kong",is_practice:false,is_example:true))
            return ProductDetail(project:p,meetings:timeline,items:[],preparations:[],followups:[],recordings:[])
        }
    }
    func openScope(_ scope:[String:Any]) async throws {
        guard remote else{throw PrototypeError.message("请先连接后端，再问 Candid。")}
        let generation=UUID();productScopeGeneration=generation
        let thread:ChatThread=try await api.call("/v1/chat/scopes",method:"POST",body:scope)
        guard productScopeGeneration==generation,!Task.isCancelled else {throw CancellationError()}
        // Scope containers participate in existing task/voice recovery but are absent from business projects.
        try await reloadProjectSpaces();guard productScopeGeneration==generation,!Task.isCancelled else{throw CancellationError()};try await loadChat(thread.id)
    }
    func productOperation(_ operation:() async throws->Void) async {
        await perform {try await operation();try await reloadProducts();try await reloadProjectSpaces()}
    }
}

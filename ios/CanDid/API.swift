import Foundation
import Security

enum ImportedDocumentFiles {
    /// Read through the provider so iCloud/WeChat can materialize their file first.
    /// Upload only an app-owned copy, never a temporary picker URL.
    static func copy(_ source:URL,into folder:URL,maxBytes:Int) async throws -> URL {
        try await Task.detached(priority:.userInitiated) {
            let access=source.startAccessingSecurityScopedResource()
            defer {if access {source.stopAccessingSecurityScopedResource()}}
            let manager=FileManager.default
            try manager.createDirectory(at:folder,withIntermediateDirectories:true)
            let target=folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension.lowercased())
            var coordinationError:NSError?
            var result:Result<URL,Error>?
            NSFileCoordinator().coordinate(readingItemAt:source,options:.withoutChanges,error:&coordinationError) {readable in
                do {
                    let metadata=try readable.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
                    guard metadata.isRegularFile==true else {throw PrototypeError.message("请选择一个文件。")}
                    if let size=metadata.fileSize,size>maxBytes {throw PrototypeError.message("文件超过 \(maxBytes/1_000_000) MB，请拆分后上传。")}
                    try manager.copyItem(at:readable,to:target)
                    let size=(try manager.attributesOfItem(atPath:target.path)[.size] as? NSNumber)?.intValue ?? 0
                    guard size>0 else {throw PrototypeError.message("文件为空，请重新选择。")}
                    guard size<=maxBytes else {throw PrototypeError.message("文件超过 \(maxBytes/1_000_000) MB，请拆分后上传。")}
                    try manager.setAttributes([.protectionKey:FileProtectionType.complete,.posixPermissions:0o600],ofItemAtPath:target.path)
                    result = .success(target)
                } catch {try? manager.removeItem(at:target);result = .failure(error)}
            }
            if let coordinationError {throw PrototypeError.message("文件未能读取，请先在“文件”中完成下载，再重新选择。"+coordinationError.localizedDescription)}
            guard let result else {throw PrototypeError.message("文件未能读取，请重新选择。")}
            return try result.get()
        }.value
    }
    static func isCancellation(_ error:Error)->Bool {
        let value=error as NSError
        return (value.domain==NSCocoaErrorDomain && value.code==NSUserCancelledError) || (value.domain==NSURLErrorDomain && value.code==NSURLErrorCancelled)
    }
    /// Relative paths survive an iOS data-container move after an app update.
    static func localURL(_ path:String,in root:URL)->URL? {
        let parts=path.split(separator:"/")
        guard parts.count>=2,parts[parts.count-2]=="OnboardingFiles" else{return nil}
        let name=String(parts.last!)
        guard UUID(uuidString:URL(fileURLWithPath:name).deletingPathExtension().lastPathComponent) != nil else{return nil}
        return root.appendingPathComponent("OnboardingFiles").appendingPathComponent(name)
    }
}
enum BackendConfiguration {
    static let baseURL = "https://47.129.137.212"
    static let previousCloudBaseURLs = ["https://16.144.9.183"]
    static let credentialAccount = "candid-cloud-access-v1"
    static let installationAccount = "candid-cloud-installation-v1"
}
struct DeviceRegistrationResponse: Decodable {
    var access_token: String
    var owner_id: String
}
import CryptoKit

enum TokenVault {
    static let service = "com.candid.prototype"
    #if DEBUG && targetEnvironment(simulator)
    // Unsigned local simulator builds do not have a Keychain access group.
    // Store only the local backend token in the app sandbox; release/device
    // builds continue to use Keychain. Provider API keys never enter the app.
    private static func simulatorURL(_ account: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CanDidTokens", isDirectory: true)
            .appendingPathComponent(Data(account.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") + ".token")
    }
    #endif
    static func read(account: String = "api-token") -> String {
        #if DEBUG && targetEnvironment(simulator)
        return (try? String(contentsOf: simulatorURL(account), encoding: .utf8)) ?? ""
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
        #endif
    }
    static func save(_ token: String, account: String = "api-token") throws {
        #if DEBUG && targetEnvironment(simulator)
        let url = simulatorURL(account)
        if token.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #else
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PrototypeError.message("无法更新访问令牌") }
        var add = query; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw PrototypeError.message("无法保存访问令牌") }
        #endif
    }
}
struct API {
    var base: String; var token: String
    func url(_ path: String) throws -> URL {
        guard let root = URL(string: base), ["http", "https"].contains(root.scheme ?? ""), root.host != nil,
              let result = URL(string: path, relativeTo: root)?.absoluteURL else { throw PrototypeError.message("请输入完整的后端地址") }
        return result
    }
    func raw(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: try url(path)); request.httpMethod = method
        request.timeoutInterval = path.hasPrefix("/v1/chat/") && method == "POST" ? 240 : 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrototypeError.message("后端没有响应") }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(APIError.self, from: data)
            throw PrototypeError.message((error?.error.code ?? String(http.statusCode)) + "：" + (error?.error.message ?? "请求失败"))
        }
        return data
    }
    func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: await raw(path, method: method, body: body))
    }
    func events(taskID: String, after: Int, receive: @MainActor (AgentEvent) -> Void) async throws {
        var request = URLRequest(url: try url("/v1/agent/tasks/" + taskID + "/events?after=" + String(after)))
        request.timeoutInterval = 60
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(String(after), forHTTPHeaderField: "Last-Event-ID")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true else {
            throw PrototypeError.message("任务连接暂时不可用，将重新读取任务状态。")
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let event = try JSONDecoder().decode(AgentEvent.self, from: Data(line.dropFirst(6).utf8))
            guard event.task_id == taskID else { throw PrototypeError.message("任务事件不匹配") }
            await receive(event)
        }
    }
    func all<T: Decodable>(_ path: String) async throws -> [T] {
        var rows: [T] = []; var cursor: String? = nil
        repeat {
            let suffix = cursor.map { "&cursor=" + $0 } ?? ""
            let page: Page<T> = try await call(path + (path.contains("?") ? "&" : "?") + "limit=100" + suffix)
            rows += page.data; cursor = page.next_cursor
        } while cursor != nil
        return rows
    }
    func upload(_ file: URL, session: String, durationMS: Int) async throws {
        let local=try FileHandle(forReadingFrom:file)
        defer { try? local.close() }
        let total=try local.seekToEnd();try local.seek(toOffset:0)
        var hasher=SHA256()
        while let data=try local.read(upToCount:1024*1024),!data.isEmpty { hasher.update(data:data) }
        let digest=hasher.finalize().map{String(format:"%02x",$0)}.joined()
        let state:UploadState=try await call("/v1/sessions/"+session+"/upload-state")
        if let media=state.media {
            guard media.bytes==Int(total),media.sha256==digest else { throw PrototypeError.message("场次已入库其他音频，本机文件保留。") }
            return
        }
        var offset=state.offset
        guard offset>=0,offset<=Int(total) else { throw PrototypeError.message("服务端上传位置异常，本机文件保留。") }
        try local.seek(toOffset:UInt64(offset))
        var receipt:MediaReceipt?
        while let chunk=try local.read(upToCount:1024*1024),!chunk.isEmpty {
            let link:Link=try await call("/v1/sessions/"+session+"/upload-url",method:"POST")
            guard let path=link.upload_url else { throw PrototypeError.message("缺少上传地址") }
            var request=URLRequest(url:try url(path+"?offset="+String(offset)+"&final="+(offset+chunk.count==Int(total) ? "true":"false")));request.httpMethod="PUT"
            request.httpBody=chunk;request.timeoutInterval=120
            request.setValue(file.pathExtension=="wav" ? "audio/wav":"audio/mp4",forHTTPHeaderField:"Content-Type")
            let (data,response)=try await URLSession.shared.data(for:request)
            guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else { throw PrototypeError.message("上传中断，本机文件保留，可继续上传。") }
            receipt=try JSONDecoder().decode(MediaReceipt.self,from:data);offset+=chunk.count
            guard receipt?.bytes==offset else { throw PrototypeError.message("上传位置不一致，请刷新后继续。") }
        }
        if receipt==nil {
            let link:Link=try await call("/v1/sessions/"+session+"/upload-url",method:"POST")
            guard let path=link.upload_url else { throw PrototypeError.message("缺少上传地址") }
            var request=URLRequest(url:try url(path+"?offset="+String(offset)));request.httpMethod="PUT";request.httpBody=Data()
            let (data,response)=try await URLSession.shared.data(for:request)
            guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else { throw PrototypeError.message("读取上传校验失败") }
            receipt=try JSONDecoder().decode(MediaReceipt.self,from:data)
        }
        guard let receipt,receipt.bytes==Int(total),receipt.sha256==digest else { throw PrototypeError.message("HASH_MISMATCH：文件保留，未确认同步。") }
        var body=try JSONSerialization.jsonObject(with:JSONEncoder().encode(receipt)) as? [String:Any] ?? [:]
        body["duration_ms"]=durationMS
        _=try await raw("/v1/sessions/"+session+"/media",method:"POST",body:body)
        // Do not delete the local recording until server acknowledges its SHA256.
    }
}


extension API {
    func uploadPDF(_ file:URL,workspaceID:String,title:String) async throws -> Data {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("DocumentImports")
        let local=try await ImportedDocumentFiles.copy(file,into:folder,maxBytes:20_000_000)
        defer {try? FileManager.default.removeItem(at:local)}
        var components=URLComponents(url:try url("/v1/materials/pdf"),resolvingAgainstBaseURL:false)!
        components.queryItems=[URLQueryItem(name:"workspace_id",value:workspaceID),URLQueryItem(name:"title",value:title)]
        var request=URLRequest(url:components.url!);request.httpMethod="POST";request.timeoutInterval=120
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/pdf",forHTTPHeaderField:"Content-Type")
        let (raw,response)=try await URLSession.shared.upload(for:request,fromFile:local)
        guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else {
            let error=try? JSONDecoder().decode(APIError.self,from:raw)
            throw PrototypeError.message(error?.error.message ?? "PDF导入失败")
        }
        return raw
    }
}

struct UploadState:Decodable { var offset:Int;var media:MediaReceipt? }

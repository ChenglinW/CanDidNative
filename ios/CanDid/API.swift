import Foundation
import Security
import CryptoKit

enum TokenVault {
    static let service = "com.candid.prototype"
    static func read(account: String = "api-token") -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account, kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ token: String, account: String = "api-token") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if token.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw PrototypeError.message("无法更新访问令牌") }
        var add = query; add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw PrototypeError.message("无法保存访问令牌") }
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
        request.timeoutInterval = 30; request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
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
        let link: Link = try await call("/v1/sessions/"+session+"/upload-url", method: "POST")
        guard let path = link.upload_url else { throw PrototypeError.message("缺少音频上传地址") }
        var request = URLRequest(url: try url(path)); request.httpMethod = "PUT"
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: file)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PrototypeError.message("上传失败。本机录音已保留，可重试。") }
        let receipt = try JSONDecoder().decode(MediaReceipt.self, from: data)
        let local = try Data(contentsOf: file)
        let digest = SHA256.hash(data: local).map { String(format: "%02x", $0) }.joined()
        guard receipt.bytes == local.count, receipt.sha256 == digest else { throw PrototypeError.message("HASH_MISMATCH：服务端与本机录音不一致，文件保留待重试。") }
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
        json?["duration_ms"] = durationMS
        _ = try await raw("/v1/sessions/"+session+"/media", method: "POST", body: json)
        // Do not delete the local recording until server acknowledges its SHA256.
    }
}

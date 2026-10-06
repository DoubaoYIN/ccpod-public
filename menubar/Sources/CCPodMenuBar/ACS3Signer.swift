import Foundation
import CryptoKit

/// 阿里云 OpenAPI V3 签名（ACS3-HMAC-SHA256）。
/// 算法：https://help.aliyun.com/zh/sdk/product-overview/v3-request-structure-and-signature
/// 实现已用官方文档示例做已知答案测试（quota_parsers.swift「ACS3签名KAT」），
/// 改动此文件必须保那条测试通过。
///
/// 用于百炼 Token Plan 额度查询（GetSubscriptionStats）：那组接口只认 RAM AccessKey 签名，
/// 明确不支持模型 key（sk-）的 Bearer 认证。
enum ACS3Signer {
    /// 组装一次已签名的 GET 请求（无 query、空 body——GetSubscriptionStats 的形态）。
    /// AK 从钥匙串来（ccpod-aliyun-ak-id / -secret），绝不落盘。
    static func signedGetRequest(url: URL, action: String, apiVersion: String,
                                 accessKeyId: String, secret: String) -> URLRequest? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = comps.host else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let payloadHash = hex(SHA256.hash(data: Data()))
        let headers: [String: String] = [
            "host": host + (comps.port.map { ":\($0)" } ?? ""),
            "x-acs-action": action,
            "x-acs-version": apiVersion,
            "x-acs-date": utcFormatter.string(from: Date()),
            "x-acs-signature-nonce": UUID().uuidString.lowercased(),
            "x-acs-content-sha256": payloadHash,
            "accept": "application/json",
        ]
        for (name, value) in headers where name != "accept" {
            req.setValue(value, forHTTPHeaderField: name)
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(
            authorization(method: "GET",
                          path: comps.path.isEmpty ? "/" : comps.path,
                          query: [:],
                          headers: headers,
                          payloadHash: payloadHash,
                          accessKeyId: accessKeyId,
                          secret: secret),
            forHTTPHeaderField: "Authorization")
        return req
    }

    /// 返回 Authorization 头的值。headers 传全部请求头，
    /// 内部只取 host / content-type / x-acs-* 参与签名。
    static func authorization(method: String, path: String, query: [String: String],
                              headers: [String: String], payloadHash: String,
                              accessKeyId: String, secret: String) -> String {
        let signed = canonicalHeaders(headers)
        let canonicalRequest = [
            method.uppercased(),
            encodePath(path),
            canonicalQuery(query),
            signed.canonical,
            signed.names,
            payloadHash,
        ].joined(separator: "\n")
        let stringToSign = "ACS3-HMAC-SHA256\n" + hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
        let signature = hex(HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(secret.utf8))))
        return "ACS3-HMAC-SHA256 Credential=\(accessKeyId),SignedHeaders=\(signed.names),Signature=\(signature)"
    }

    // MARK: - 规则细节

    private static func canonicalHeaders(_ headers: [String: String]) -> (canonical: String, names: String) {
        let included = headers
            .compactMap { item -> (name: String, value: String)? in
                let name = item.key.lowercased()
                guard name == "host" || name == "content-type" || name.hasPrefix("x-acs-") else { return nil }
                return (name, item.value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .sorted { $0.name < $1.name }
        // 每条头以 \n 结尾（最后一条也带），因此 SignedHeaders 行前有一个空行——与文档一致
        let canonical = included.map { "\($0.name):\($0.value)\n" }.joined()
        let names = included.map(\.name).joined(separator: ";")
        return (canonical, names)
    }

    private static func canonicalQuery(_ query: [String: String]) -> String {
        query
            .sorted { $0.key < $1.key }
            .map { percentEncode($0.key) + "=" + percentEncode($0.value) }
            .joined(separator: "&")
    }

    /// RFC3986：A-Za-z0-9 与 -_.~ 不编码；空格→%20、*→%2A；其余编为 %XX（大写十六进制）。
    static func percentEncode(_ raw: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    /// path 按 `/` 分段编码，`/` 本身保留（文档：对被 / 分隔的每段做编码）。
    private static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~/")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static let utcFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

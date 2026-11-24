import Foundation

/// 哪些地址可以为了链接预览去访问。只放行公开网址：复制一个内网地址不应该让本应用去探测它。
public enum LinkPolicy {
    /// 文本是一个可以访问的 http(s) 公开网址时返回它。
    public static func fetchableURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, let host = url.host(percentEncoded: false), isPublicHost(host) else { return nil }
        return url
    }

    public static func isPublicHost(_ host: String) -> Bool {
        var host = host.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host.contains(":") { return isPublicAddress(host) }
        // inet_aton 认得 127.1、0x7f.0.0.1、2130706433 这类写法，都按 IP 地址判断。
        var v4 = in_addr()
        if inet_aton(host, &v4) != 0 { return isPublic(v4) }
        // 没有点的主机名是内网里的短名字。
        guard host.contains(".") else { return false }
        return !["localhost", "local", "internal", "lan", "intranet", "home.arpa", "corp", "home"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 数字形式的 IPv4 或 IPv6 地址是否是公网地址。域名解析出的地址也用它检查。
    public static func isPublicAddress(_ address: String) -> Bool {
        // 去掉 IPv6 的接口后缀（fe80::1%en0）。
        let address = String(address.split(separator: "%").first ?? "")
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return isPublic(v4) }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) { return false } // :: 和 ::1
        if bytes[0] & 0xFE == 0xFC { return false } // fc00::/7 本地唯一地址
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false } // fe80::/10 链路本地
        if bytes[0] == 0xFF { return false } // 组播
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            // 映射成 IPv6 的 IPv4 地址。
            return isPublic(in_addr(s_addr: UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24))
        }
        return true
    }

    private static func isPublic(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let a = value >> 24, b = (value >> 16) & 0xFF
        switch a {
        case 0, 10, 127: return false
        case 100 where (64...127).contains(b): return false // 运营商级 NAT
        case 169 where b == 254: return false // 链路本地
        case 172 where (16...31).contains(b): return false
        case 192 where b == 168: return false
        case 224...: return false // 组播和保留
        default: return true
        }
        // 198.18.0.0/15 有意不算内网：代理软件的 fake-ip 模式会把所有域名都解析到这一段。
    }
}

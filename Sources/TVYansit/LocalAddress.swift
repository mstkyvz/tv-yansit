import Darwin
import Foundation

struct LocalAddress: Hashable {
    let interface: String
    let ip: String
}

enum LocalAddresses {
    /// Fiziksel ag arayuzlerindeki (en0, en1...) IPv4 adresleri.
    static func all() -> [LocalAddress] {
        var result: [LocalAddress] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(LocalAddress(interface: name, ip: String(cString: host)))
            }
        }
        return result
    }

    /// Internete cikan yolun kaynak adresi. Bu, elle eklenmis ek IP'leri ve
    /// (VPN kapaliyken) sanal arayuzleri atlayarak dogru adresi verir.
    static func primaryIP() -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(53).bigEndian
        inet_pton(AF_INET, "8.8.8.8", &remote.sin_addr)
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    /// Listeyi en olasi dogru adres basta olacak sekilde siralar.
    static func ordered() -> [LocalAddress] {
        let all = all()
        guard let primary = primaryIP(), let index = all.firstIndex(where: { $0.ip == primary }) else {
            return all
        }
        var sorted = all
        sorted.insert(sorted.remove(at: index), at: 0)
        return sorted
    }
}

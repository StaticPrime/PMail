import Foundation

extension GoogleMailService {
    /// The units PMail lets itself spend with Google's mail API in a minute. Google allows each person 6,000; PMail
    /// keeps 500 back for what its own count can't see (the same account in PMail on another Mac, say).
    static let unitsPerMinute = 5_500
    /// The share of the minute background work may fill, leaving the rest for what the person does.
    static let backgroundShare = 0.25
    /// The most requests PMail has going at once for an account. Google doesn't say how many it allows; a few more
    /// than this and it starts refusing.
    static let requestsAtOnce = 6

    /// What a request costs in Google's quota units, from the per-method table on its quota page (November 2026).
    /// Anything the table doesn't give counts as 20, as much as most of what it does.
    static func quotaCost(_ method: String, _ url: URL) -> Int {
        let path = url.path
        guard let start = path.range(of: "/gmail/v1/users/me/") else { return 20 }
        let parts = path[start.upperBound...].split(separator: "/").map(String.init)
        let method = method.uppercased()
        let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "format" }?.value?.lowercased() ?? ""
        let whole = ["full", "raw", "html"].contains(format)
        switch parts.first ?? "" {
        case "history": return 2
        case "profile": return 1
        case "labels": return method == "GET" ? 1 : 5
        case "settings": return method == "GET" ? 1 : 100  // The send-as addresses, which hold the signature.
        case "watch": return 100
        case "stop": return 50
        case "threads":
            guard parts.count > 1 else { return 10 }  // threads.list
            guard parts.count > 2 else {
                return method == "GET" ? (format == "full" ? 120 : 40) : 20  // threads.get, threads.delete
            }
            switch parts[2] {
            case "modify", "untrash": return 10
            default: return 20  // threads.trash
            }
        case "messages":
            guard parts.count > 1 else { return method == "GET" ? 5 : 25 }  // messages.list, messages.insert
            switch parts[1] {
            case "send": return 100
            case "batchModify", "batchDelete": return 50
            case "import": return 25
            default: break
            }
            guard parts.count > 2 else { return method == "GET" ? (whole ? 60 : 20) : 10 }  // messages.get, messages.delete
            switch parts[2] {
            case "modify", "untrash": return 5
            default: return 20  // messages.trash, messages.attachments.get
            }
        case "drafts":
            guard parts.count > 1 else { return method == "GET" ? 5 : 10 }  // drafts.list, drafts.create
            if parts[1] == "send" { return 100 }
            switch method {
            case "GET": return whole ? 60 : 20
            case "PUT": return 15
            case "DELETE": return 10
            default: return 20
            }
        default:
            return 20
        }
    }
}

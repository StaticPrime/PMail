import AppKit
import PMailKit
import SwiftUI
import WebKit

/// A message's body, drawn by WebKit at its full height inside the conversation's scroll view. The message's own
/// scripts never run, links open in the browser, and the page never reaches the internet itself: pictures, style
/// sheets and fonts from the internet come through PMail's private loader (from the account's copy when there is
/// one), and only when Settings ▸ Privacy lets them.
struct MessageBodyView: NSViewRepresentable {
    let message: MailMessage
    let loadsRemoteImages: Bool
    /// The account's copies of remote content, which pictures come from (and are kept in) when they load.
    var cache: RemoteContentCache?
    @Binding var height: CGFloat
    var onMailto: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    #if DEBUG
    /// The remote content message pages were given, for the self-test.
    static var remoteContentServed: [URL] = []
    #endif

    func makeNSView(context: Context) -> BodyWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: "cid")
        configuration.setURLSchemeHandler(context.coordinator, forURLScheme: RemoteContent.scheme)
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "pmHeight")
        controller.addUserScript(WKUserScript(source: Self.heightScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                              in: .defaultClient))
        let webView = BodyWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = false
        context.coordinator.load(into: webView)
        return webView
    }

    func updateNSView(_ webView: BodyWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.loadedID != message.id || coordinator.loadedRemote != loadsRemoteImages {
            coordinator.load(into: webView)
        }
    }

    static func dismantleNSView(_ webView: BodyWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pmHeight", contentWorld: .defaultClient)
        coordinator.cancelLoads()
    }

    /// Reports the page's height whenever it changes, from the app's own script world (the page's scripts are off).
    private static let heightScript = """
    (function() {
        function post() { window.webkit.messageHandlers.pmHeight.postMessage(Math.ceil(document.documentElement.scrollHeight)); }
        if (window.ResizeObserver) { new ResizeObserver(post).observe(document.documentElement); }
        window.addEventListener('load', post);
        post();
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKURLSchemeHandler {
        var parent: MessageBodyView
        var loadedID: String?
        var loadedRemote = false
        /// Remote content being loaded for the page, by the request it answers.
        private var loads: [ObjectIdentifier: Task<Void, Never>] = [:]

        init(_ parent: MessageBodyView) {
            self.parent = parent
        }

        func load(into webView: WKWebView) {
            loadedID = parent.message.id
            loadedRemote = parent.loadsRemoteImages
            cancelLoads()
            let html = MessageHTML.document(for: parent.message, allowsRemote: parent.loadsRemoteImages)
            let controller = webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            // The page itself never reaches the internet (what loads comes through PMail's loader), and nothing loads
            // until the rules that make sure of it are in place.
            RemoteContentBlocker.rules { rules in
                if let rules { controller.add(rules) }
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func cancelLoads() {
            loads.values.forEach { $0.cancel() }
            loads = [:]
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double ?? (message.body as? Int).map(Double.init) else { return }
            let height = max(24, min(CGFloat(value), 200_000))
            if abs(parent.height - height) > 1 { parent.height = height }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // Only the message itself loads here. A click goes to the browser; anything else (a refresh tag, a
            // frame) goes nowhere.
            guard navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil, let url else {
                decisionHandler(url == nil || url?.scheme == "about" ? .allow : .cancel)
                return
            }
            decisionHandler(.cancel)
            switch url.scheme?.lowercased() {
            case "mailto": parent.onMailto(url)
            case "http", "https", "tel", "facetime", "facetime-audio", "sms", "maps", "webcal": NSWorkspace.shared.open(url)
            default: break
            }
        }

        // MARK: cid: pictures, and remote content through PMail's loader

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            guard let url = urlSchemeTask.request.url else { return }
            if url.scheme?.lowercased() == RemoteContent.scheme { return loadRemote(url, for: urlSchemeTask) }
            let id = (url.absoluteString.dropFirst("cid:".count).removingPercentEncoding ?? "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            let part = (parent.message.inlineParts + parent.message.attachments).first { $0.contentID == id }
            guard let part, let data = part.data else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            urlSchemeTask.didReceive(URLResponse(url: url, mimeType: part.mimeType, expectedContentLength: data.count, textEncodingName: nil))
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            loads.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
        }

        /// A picture, style sheet or font from the internet, from the account's copy or loaded privately now. Only
        /// for a page allowed remote content; otherwise (or for anything PMail won't load) the page gets nothing.
        private func loadRemote(_ url: URL, for task: any WKURLSchemeTask) {
            guard loadedRemote, let reference = RemoteContent.reference(from: url) else {
                task.didFailWithError(URLError(.resourceUnavailable))
                return
            }
            let key = ObjectIdentifier(task)
            let cache = parent.cache
            loads[key] = Task { [weak self] in
                let result: Result<RemoteResource, any Error>
                do {
                    result = .success(try await RemoteContentLoader.shared.load(reference, cache: cache))
                } catch {
                    result = .failure(error)
                }
                // A request WebKit stopped meanwhile mustn't be answered.
                guard let self, self.loads.removeValue(forKey: key) != nil, !Task.isCancelled else { return }
                switch result {
                case let .success(resource):
                    #if DEBUG
                    MessageBodyView.remoteContentServed.append(reference.url)
                    #endif
                    var headers = ["Content-Type": resource.mimeType + (resource.textEncoding.map { "; charset=\($0)" } ?? ""),
                                   "Content-Length": String(resource.data.count)]
                    // Fonts load only when the server says any page may use them.
                    headers["Access-Control-Allow-Origin"] = "*"
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                        ?? URLResponse(url: url, mimeType: resource.mimeType, expectedContentLength: resource.data.count, textEncodingName: resource.textEncoding)
                    task.didReceive(response)
                    task.didReceive(resource.data)
                    task.didFinish()
                case let .failure(error):
                    task.didFailWithError(error)
                }
            }
        }
    }
}

/// A web view that doesn't scroll itself: vertical scrolling goes to the conversation around it.
final class BodyWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The rules that keep a message's page from loading anything from the internet itself. What it's allowed comes
/// through PMail's loader instead (`pmail-remote:`), which these leave alone.
enum RemoteContentBlocker {
    private static var compiled: WKContentRuleList?
    private static var waiting: [(WKContentRuleList?) -> Void] = []
    private static var compiling = false

    static func rules(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let compiled { return completion(compiled) }
        waiting.append(completion)
        guard !compiling else { return }
        compiling = true
        // WebKit's rule language has no alternation, so one rule per scheme.
        let json = ["^https?://", "^wss?://", "^ftp://"].map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"# }
        let list = "[" + json.joined(separator: ",") + "]"
        WKContentRuleListStore.default()?.compileContentRuleList(forIdentifier: "PMailBlockRemoteContent", encodedContentRuleList: list) { list, _ in
            MainActor.assumeIsolated {
                compiled = list
                compiling = false
                let callbacks = waiting
                waiting = []
                callbacks.forEach { $0(list) }
            }
        }
    }
}

/// The page a message body is shown in.
enum MessageHTML {
    static func document(for message: MailMessage, allowsRemote: Bool = false) -> String {
        // The page may show its own pictures (cid: and data:), and the internet's only when allowed, through PMail's
        // loader; it never reaches the internet itself, runs scripts, opens frames or sends forms, and its links
        // aren't looked up ahead of a click.
        let remote = allowsRemote ? " \(RemoteContent.scheme):" : ""
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src cid: data:\(remote); "
            + "style-src 'unsafe-inline'\(remote); font-src data:\(remote); media-src cid: data:; form-action 'none'; frame-src 'none'; "
            + "script-src 'none'\"><meta http-equiv=\"x-dns-prefetch-control\" content=\"off\">"
        let isHTML = !(message.htmlBody?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        // Formatted mail is drawn for white paper, so it stays light (on a white card in Dark Mode); plain text
        // follows the window's appearance.
        let style = policy + """
        <style>
        :root { color-scheme: \(isHTML ? "light" : "light dark"); }
        html, body { margin: 0; padding: 0; background: transparent; }
        body { font: 14px -apple-system, Helvetica, Arial, sans-serif; color: #222; word-wrap: break-word; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        pre, .pm-plain { white-space: pre-wrap; font: 14px -apple-system, Helvetica, Arial, sans-serif; margin: 0; }
        blockquote { margin: 0 0 0 .8ex; border-left: 1px solid #ccc; padding-left: 1ex; color: #555; }
        a { color: #1557e8; }
        \(isHTML ? "" : "@media (prefers-color-scheme: dark) { body { color: #e3e3e3; } a { color: #8ab4f8; } blockquote { color: #aaa; border-color: #555; } }")
        </style>
        """
        if var html = message.htmlBody, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if allowsRemote { html = RemoteContent.rewrite(html: html).html }
            // Keep the sender's document as it is, with the base style in front.
            if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                var result = html
                result.insert(contentsOf: "<meta charset=\"utf-8\">" + style, at: head.upperBound)
                return result
            }
            return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\(style)</head><body>\(html)</body></html>"
        }
        let text = message.textBody ?? ""
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\">\(style)</head><body><div class=\"pm-plain\">\(linkify(text))</div></body></html>"
    }

    /// Plain text as HTML, with links made clickable and quoted lines set off.
    static func linkify(_ text: String) -> String {
        var html = ""
        var quoteDepth = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var depth = 0
            var rest = Substring(line)
            while rest.hasPrefix(">") { depth += 1; rest = rest.dropFirst(); if rest.hasPrefix(" ") { rest = rest.dropFirst() } }
            while quoteDepth < depth { html += "<blockquote>"; quoteDepth += 1 }
            while quoteDepth > depth { html += "</blockquote>"; quoteDepth -= 1 }
            html += linkifyLine(String(rest)) + "\n"
        }
        while quoteDepth > 0 { html += "</blockquote>"; quoteDepth -= 1 }
        return html
    }

    private static func linkifyLine(_ line: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return ReplyBuilder.escapeHTML(line)
        }
        var html = ""
        var last = line.startIndex
        for match in detector.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
            guard let range = Range(match.range, in: line), let url = match.url else { continue }
            html += ReplyBuilder.escapeHTML(String(line[last..<range.lowerBound]))
            html += "<a href=\"\(ReplyBuilder.escapeHTML(url.absoluteString))\">\(ReplyBuilder.escapeHTML(String(line[range])))</a>"
            last = range.upperBound
        }
        return html + ReplyBuilder.escapeHTML(String(line[last...]))
    }

    /// Whether the body asks for anything from the internet that PMail would load (pictures, mostly), so the
    /// "pictures are hidden" note shows.
    static func hasRemoteContent(_ message: MailMessage) -> Bool {
        guard let html = message.htmlBody else { return false }
        return !RemoteContent.references(in: html).isEmpty
    }
}

import Foundation
import Network
import Testing
@testable import PMailKit

struct RemoteContentTests {
    private func address(_ url: String, _ kind: RemoteReference.Kind = .content) -> String {
        RemoteContent.address(for: RemoteReference(URL(string: url)!, kind: kind))
    }

    @Test func picturesPointAtTheLoader() {
        let html = #"<p>Hi</p><img src="https://pics.example/a.png?x=1&amp;y=2" alt=""><IMG SRC='http://pics.example/b.gif'><img src=//cdn.example/c.jpg>"#
        let result = RemoteContent.rewrite(html: html)
        #expect(result.references.map(\.url.absoluteString) == ["https://pics.example/a.png?x=1&y=2", "http://pics.example/b.gif", "https://cdn.example/c.jpg"],
                "entities decoded, protocol-relative addresses taken as https")
        #expect(result.html.contains(#"src="\#(address("https://pics.example/a.png?x=1&y=2"))""#))
        #expect(result.html.contains(#"SRC="\#(address("http://pics.example/b.gif"))""#))
        #expect(!result.html.contains("pics.example") && !result.html.contains("cdn.example"), "no address is left for the page to reach")
        #expect(result.html.hasPrefix("<p>Hi</p><img src=") && result.html.contains(#" alt="">"#), "the rest is unchanged")
    }

    @Test func onlyWhatLoadsAsPicturesOrStylesChanges() {
        let html = """
        <a href="https://example.com/offer">Offer</a><img src="cid:logo@x"><img src="data:image/png;base64,AAAA">
        <script src="https://bad.example/x.js"></script><iframe src="https://bad.example/frame"></iframe>
        <video src="https://bad.example/v.mp4" poster="https://bad.example/p.jpg"></video>
        <!-- <img src="https://hidden.example/pixel.gif"> --><link rel="icon" href="https://bad.example/icon.png">
        <textarea><img src="https://bad.example/text.png"></textarea>
        """
        let result = RemoteContent.rewrite(html: html)
        #expect(result.references.isEmpty, "\(result.references)")
        #expect(result.html == html)
        #expect(RemoteContent.references(in: html).isEmpty)
    }

    @Test func srcsetsBackgroundsAndStyles() {
        let html = """
        <html><head><style>@import url("https://fonts.example/css?family=Inter"); @import 'http://styles.example/more.css';
        .hero { background: url(https://pics.example/hero.jpg) } .logo { background-image: url('data:image/png;base64,AA') }</style>
        <link rel="stylesheet" href="https://styles.example/main.css"></head>
        <body background="https://pics.example/paper.png"><table><td style="background:url(&quot;https://pics.example/cell.png&quot;); color:&quot;red&quot;">x</td></table>
        <picture><source srcset="https://pics.example/wide.webp 2x, data:image/png;base64,AAA,BBB 1x"><img srcset="https://pics.example/s.png 1x,https://pics.example/m.png 2x" src="https://pics.example/s.png"></picture>
        </body></html>
        """
        let result = RemoteContent.rewrite(html: html)
        #expect(result.references == [
            RemoteReference(URL(string: "https://fonts.example/css?family=Inter")!, kind: .style),
            RemoteReference(URL(string: "http://styles.example/more.css")!, kind: .style),
            RemoteReference(URL(string: "https://pics.example/hero.jpg")!),
            RemoteReference(URL(string: "https://styles.example/main.css")!, kind: .style),
            RemoteReference(URL(string: "https://pics.example/paper.png")!),
            RemoteReference(URL(string: "https://pics.example/cell.png")!),
            RemoteReference(URL(string: "https://pics.example/wide.webp")!),
            RemoteReference(URL(string: "https://pics.example/s.png")!),
            RemoteReference(URL(string: "https://pics.example/m.png")!),
        ], "each once, in order")
        #expect(result.html.contains(#"@import url("\#(address("https://fonts.example/css?family=Inter", .style))")"#))
        #expect(result.html.contains(#"@import "\#(address("http://styles.example/more.css", .style))""#))
        #expect(result.html.contains("url('data:image/png;base64,AA')"), "pictures in the message itself stay")
        #expect(result.html.contains(#"href="\#(address("https://styles.example/main.css", .style))""#))
        #expect(result.html.contains(#"style="background:url(&quot;\#(address("https://pics.example/cell.png"))&quot;); color:&quot;red&quot;""#),
                "a style attribute stays escaped")
        #expect(result.html.contains(#"srcset="\#(address("https://pics.example/wide.webp")) 2x, data:image/png;base64,AAA,BBB 1x""#),
                "a data: address keeps its comma")
        #expect(!result.html.contains("pics.example") && !result.html.contains("styles.example") && !result.html.contains("fonts.example"))
    }

    @Test func addressesComeBack() throws {
        let reference = RemoteReference(URL(string: "https://pics.example/a b.png?q=ü&x=1#top")!, kind: .style)
        let address = try #require(URL(string: RemoteContent.address(for: reference)))
        #expect(address.scheme == "pmail-remote" && address.host == "style")
        #expect(RemoteContent.reference(from: address) == reference)
        #expect(RemoteContent.reference(from: URL(string: "https://pics.example/a.png")!) == nil)
        #expect(RemoteContent.reference(from: URL(string: "pmail-remote://other/aGk")!) == nil)
        #expect(RemoteContent.reference(from: URL(string: "pmail-remote://content/" + WebBase64.urlEncoded(Data("file:///etc/hosts".utf8)))!) == nil,
                "only web addresses")
    }

    @Test func styleSheetsResolveTheirOwnAddresses() {
        let css = #"@import "print.css"; @font-face { src: url(../fonts/inter.woff2) } .a { background: url("/img/a.png") } .b { background: url(data:image/png;base64,AA) }"#
        let result = RemoteContent.rewrite(css: css, base: URL(string: "https://styles.example/css/main.css"))
        #expect(result.references.map(\.url.absoluteString) == ["https://styles.example/css/print.css", "https://styles.example/fonts/inter.woff2",
                                                                "https://styles.example/img/a.png"])
        #expect(result.references.first?.kind == .style)
        #expect(result.css.contains("url(data:image/png;base64,AA)"))
        #expect(RemoteContent.rewrite(css: #".a { background: url("/img/a.png") }"#, base: nil).references.isEmpty, "a message's own styles have no base")
    }

    @Test func srcsetCandidatesSplitLikeBrowsers() {
        let candidates = RemoteContent.srcsetCandidates(" a.png 1x,b.png 2x , data:image/png;base64,AA,BB 3x, c.png,")
        #expect(candidates.map(\.url) == ["a.png", "b.png", "data:image/png;base64,AA,BB", "c.png"])
        #expect(candidates.map(\.descriptor) == ["1x", "2x", "3x", ""])
    }

    @Test func onlyAddressesOnTheInternetLoad() {
        func allows(_ text: String, proxy: Bool = false) -> Bool { RemoteAddressPolicy.allows(URL(string: text)!, throughProxy: proxy) }
        #expect(allows("https://pics.example/a.png") && allows("http://203.0.113.9/a.png") && allows("https://[2001:db8::1]/a.png"))
        for local in ["http://localhost/a", "http://app.localhost/a", "http://127.0.0.1/a", "http://127.1/a", "http://2130706433/a", "http://0x7f.1/a",
                      "http://10.0.0.2/a", "http://192.168.1.1/reboot", "http://172.20.0.1/a", "http://169.254.169.254/latest", "http://100.64.0.1/a",
                      "http://0.0.0.0/a", "http://[::1]/a", "http://[fe80::1]/a", "http://[fd12::1]/a", "http://[::ffff:192.168.1.1]/a", "ftp://pics.example/a"] {
            #expect(!allows(local), "\(local)")
        }
        #expect(allows("http://intranet/a") && allows("http://nas.local/a"), "names are left to the system without a proxy")
        #expect(!allows("http://intranet/a", proxy: true) && !allows("http://nas.local/a", proxy: true), "but no proxy can carry them")
        #expect(allows("https://pics.example/a.png", proxy: true))
    }

    @Test func privateSessionsKeepNothingAndNeverGoAroundTheProxy() throws {
        let direct = try #require(PrivateSession.configuration(proxy: nil, password: nil))
        #expect(direct.httpCookieAcceptPolicy == .never && !direct.httpShouldSetCookies && direct.httpCookieStorage == nil)
        #expect(direct.urlCache == nil && direct.urlCredentialStorage == nil)
        #expect(direct.httpAdditionalHeaders?["User-Agent"] as? String == PrivateSession.userAgent)
        #expect(!PrivateSession.userAgent.contains("PMail") && !PrivateSession.userAgent.contains("CFNetwork"), "it doesn't say who asked")
        #expect(direct.proxyConfigurations.isEmpty)

        let tor = try #require(PrivateSession.configuration(proxy: RemoteContentProxy(), password: nil))
        #expect(tor.proxyConfigurations.count == 1)
        #expect(tor.proxyConfigurations.first?.allowFailover == false, "a proxy that can't be reached means nothing loads")
        let http = try #require(PrivateSession.configuration(proxy: RemoteContentProxy(kind: .http, host: "proxy.example", port: 8080, username: "me"),
                                                             password: "secret"))
        #expect(http.proxyConfigurations.first?.allowFailover == false)
        #expect(PrivateSession.configuration(proxy: RemoteContentProxy(host: " ", port: 9050), password: nil) == nil, "a proxy needs a server")
        #expect(PrivateSession.configuration(proxy: RemoteContentProxy(port: 0), password: nil) == nil, "and a port")
        #expect(PrivateFetcher(proxy: RemoteContentProxy(host: ""), password: nil) == nil)
    }
}

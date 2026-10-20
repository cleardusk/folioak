import Foundation
import PDFKit

#if TESTING
private final class SmartLiveCredentials: SmartCredentialStorage {
    private var key: String?
    func read() throws -> String? { key }
    func write(_ key: String) throws { self.key = key }
    func delete() throws { key = nil }
}
#endif

private actor ScriptedSmartTransport: HTTPTransport {
    struct Reply {
        let data: Data
        let status: Int
        let type: String
        let delay: UInt64
        init(_ object: Any, status: Int = 200, delay: UInt64 = 0) throws {
            data = try JSONSerialization.data(withJSONObject: object)
            self.status = status; type = "application/json"; self.delay = delay
        }
        init(html: String, type: String = "text/html") {
            data = Data(html.utf8); status = 200; self.type = type; delay = 0
        }
    }
    var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled = false
    init(_ replies: [Reply]) { self.replies = replies }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        do {
            if reply.delay > 0 { try await Task.sleep(nanoseconds: reply.delay) }
            try Task.checkCancellation()
        } catch { cancelled = true; throw error }
        return (reply.data, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
            headerFields: ["Content-Type": reply.type])!)
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

extension CoreTests {
    // The captured search observation is deliberately unformatted. Native UI
    // tests use the resolver result, not a hand-cleaned presentation mock.
    static func smartPaperPresentationFixture() async throws -> SmartResolution {
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            return ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant",
                "tool_calls": [["id": "fixture", "type": "function", "function": ["name": name, "arguments": arguments]]]]]]]
        }
        let title = "Improving Language Understanding by Generative Pre-Training"
        let pdf = "https://cdn.openai.com/research-covers/language-unsupervised/language_understanding_paper.pdf"
        let summary = """
        | # | Paper | Year | ID | Local copy | The one-sentence answer |
        |---|---|---|---|---|---|
        | 3 | Improving Language Understanding by Generative Pre-Training (GPT-1) — Radford et al., OpenAI | 2018 | [OpenAI PDF](\(pdf)) | `ai-engineering/readings/general/gpt1-improving-language-understanding.pdf` | Decoder-only next-token prediction at scale yields general-purpose models |
        """
        let api = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": title + " GPT-1 OpenAI paper PDF"])),
            .init(["results": [["title": "---",
                "url": "https://raw.githubusercontent.com/ramseywise/learn-ai-engineering/refs/heads/main/interviewing/notes/paper-canon.md",
                "summary": summary,
                "snippet": "#: 3; Paper: \(title) (GPT-1) — Radford et al., OpenAI; Year: 2018; ID: [OpenAI PDF](\(pdf))"]]]),
            .init(call("enqueue_download", ["selections": [["candidate_id": "r2", "title": title,
                "format": "inherit", "skip_existing": false]], "unresolved": []]))
        ])
        return try await DeepSeekResolver(api: api).resolve("下载 gpt-1 论文", apiKey: "synthetic-test-key", progress: { _ in })
    }

    static func smartResolverTests() async throws {
        func selection(_ id: String, _ format: String = "inherit", skip: Bool = false, title: String = "") -> [String: Any] {
            ["candidate_id": id, "format": format, "skip_existing": skip, "title": title]
        }
        func call(_ name: String, _ args: [String: Any], additional: Bool = false) throws -> [String: Any] {
            let arguments = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            let tool: [String: Any] = ["id": "call_test", "type": "function", "function": ["name": name, "arguments": arguments]]
            return ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                "tool_calls": additional ? [tool, tool] : [tool]]]]]
        }
        func terminal(_ selections: [[String: Any]], unresolved: [String] = []) throws -> [String: Any] {
            try call("enqueue_download", ["selections": selections, "unresolved": unresolved])
        }
        let key = "synthetic-test-key"
        let direct = try ScriptedSmartTransport([.init(terminal([selection("r2", "audio", skip: true)]))])
        let directResult = try await DeepSeekResolver(api: direct).resolve(
            "https://example.com/first.mp4 https://example.com/second.mp4 只要第二个音频，已有的跳过", apiKey: key, progress: { _ in })
        try expect(directResult.modelCalls == 1 && directResult.toolCalls == 0 && !directResult.needsReview,
                   "supplied-link conditions use one terminal model request")
        try expect(directResult.selections == [SmartSelection(candidateID: "r2", format: .audio, skipExisting: true)],
                   "per-resource format and skip conditions survive the protocol")
        let directRequests = await direct.requests
        let payload = try JSONSerialization.jsonObject(with: directRequests[0].httpBody!) as! [String: Any]
        try expect((payload["thinking"] as? [String: String])?["type"] == "disabled" && payload["stream"] as? Bool == false,
                   "thin ReAct explicitly disables long thinking and streaming")
        try expect((payload["tools"] as? [Any])?.count == 3, "only the three bounded tools are exposed")
        let punctuated = try ScriptedSmartTransport([.init(terminal([selection("r1", "audio")]))])
        let punctuationResult = try await DeepSeekResolver(api: punctuated).resolve(
            "https://example.com/video.mp4，只要音频", apiKey: key, progress: { _ in })
        try expect(punctuationResult.candidates.first?.url.absoluteString == "https://example.com/video.mp4",
                   "Chinese prose beside a URL cannot become part of its download address")
        let literalURL = "https://example.com/video.mp4?q=你好，世界；测试"
        try expect(SmartInput.isDirect(literalURL) && SmartInput.separatingCommands(literalURL) == literalURL,
                   "literal query punctuation stays on the zero-model native route")
        let literal = try ScriptedSmartTransport([.init(terminal([selection("r1", "audio")]))])
        let literalResult = try await DeepSeekResolver(api: literal).resolve(
            literalURL + " 只要音频", apiKey: key, progress: { _ in })
        try expect(literalResult.candidates.first?.url == URL(string: literalURL),
                   "conditions do not truncate punctuation inside an actual URL query")
        let paperAPI = try ScriptedSmartTransport([.init(terminal([selection("r1", skip: true)]))])
        let paperResult = try await DeepSeekResolver(api: paperAPI).resolve(
            "https://arxiv.org/abs/1706.03762v7 只要 PDF，已有的跳过", apiKey: key, progress: { _ in })
        try expect(paperResult.candidates.first?.url.absoluteString == "https://arxiv.org/abs/1706.03762v7" &&
                   paperResult.selections.first?.format == .inherit && !paperResult.needsReview,
                   "native paper proposals preserve exact versions without imposing media-format review")
        let unknown = try ScriptedSmartTransport([.init(terminal([selection("r1")]))])
        let unknownResult = try await DeepSeekResolver(api: unknown).resolve(
            "保存 https://example.com/project 的论文", apiKey: key, progress: { _ in })
        try expect(unknownResult.needsReview, "an uninspected supplied webpage cannot auto-submit as a verified file")

        let search = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "Attention Is All You Need arxiv"])),
            .init(["results": [["title": "Attention Is All You Need", "url": "https://arxiv.org/abs/1706.03762", "summary": "A paper candidate"]]]),
            .init(terminal([selection("r1", title: "Attention Is All You Need")]))
        ])
        let searched = try await DeepSeekResolver(api: search).resolve("找提出 Transformer 的论文", apiKey: key, progress: { _ in })
        try expect(searched.needsReview && searched.modelCalls == 2 && searched.toolCalls == 1,
                   "search discovery always requires review, even when only one result exists")
        try expect(searched.candidates.first?.observedTitle == "Attention Is All You Need" &&
                   searched.candidates.first?.detail == "", "observed search titles are retained without leaking raw snippets")
        let searchRequests = await search.requests
        let secondPayload = try JSONSerialization.jsonObject(with: searchRequests[2].httpBody!) as! [String: Any]
        let messages = secondPayload["messages"] as! [[String: Any]]
        try expect(messages.last?["role"] as? String == "tool" &&
                   (messages.last?["content"] as? String)?.contains("1706.03762") == true,
                   "the next decision observes the real tool result")
        let unrelated = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "requested original paper"])),
            .init(["results": [["title": "Unrelated training system", "url": "https://www.cs.princeton.edu/deepspeed.pdf",
                                "summary": "This different paper cites the requested work in its references."]]]),
            .init(terminal([], unresolved: ["未找到目标论文"]))
        ])
        let rejected = try await DeepSeekResolver(api: unrelated).resolve("下载指定的原始论文", apiKey: key, progress: { _ in })
        try expect(rejected.candidates.isEmpty && rejected.selections.isEmpty && !rejected.unresolved.isEmpty,
                   "a rejected but downloadable search hit is never exposed as a selectable candidate")
        let cited = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "Original Formal Title"])),
            .init(["results": [["title": "A collection of different papers", "url": "https://example.com/notes.md",
                                "summary": "", "snippet": "Original Formal Title — Ada Example (2019). [Official PDF](https://papers.example.edu/original.pdf)."]]]),
            .init(terminal([selection("r2", title: "Original Formal Title")]))
        ])
        let citation = try await DeepSeekResolver(api: cited).resolve("下载这篇原始论文", apiKey: key, progress: { _ in })
        try expect(citation.candidates.count == 1 && citation.candidates[0].url.absoluteString == "https://papers.example.edu/original.pdf" &&
                   citation.candidates[0].title == "Original Formal Title" &&
                   citation.candidates[0].observedTitle == "Original Formal Title" && citation.candidates[0].detail.isEmpty,
                   "an observed attachment title is separated from private evidence and the citing page's title")
        let citedRequests = await cited.requests
        let citedPayload = try JSONSerialization.jsonObject(with: citedRequests[2].httpBody!) as! [String: Any]
        let citedMessages = citedPayload["messages"] as! [[String: Any]]
        let citedObservation = try JSONSerialization.jsonObject(with: Data((citedMessages.last!["content"] as! String).utf8)) as! [String: Any]
        let attachmentObservation = (citedObservation["resources"] as! [[String: Any]]).first { $0["id"] as? String == "r2" }
        try expect(attachmentObservation?["title"] as? String == "" &&
                   (attachmentObservation?["detail"] as? String)?.contains("Original Formal Title") == true,
                   "an attachment filename is not mislabeled as an observed formal title in the model's input")
        try expect((citedMessages.last?["content"] as? String)?.contains("observed_in") == true &&
                   (citedMessages.last?["content"] as? String)?.contains("Original Formal Title") == true &&
                   (citedMessages.last?["content"] as? String)?.contains("Ada Example") == true,
                   "nonempty snippets and citation provenance reach the decision after an empty summary")
        let presentation = try await smartPaperPresentationFixture()
        try expect(presentation.candidates.count == 1 &&
                   presentation.candidates[0].observedTitle == "Improving Language Understanding by Generative Pre-Training" &&
                   presentation.candidates[0].title == presentation.candidates[0].observedTitle &&
                   presentation.candidates[0].detail.isEmpty && !presentation.candidates[0].title.contains("|"),
                   "captured Markdown table yields the formal paper title without exposing table syntax or its filename")
        let gpt2Title = "Language Models are Unsupervised Multitask Learners"
        let markdown = """
        # Language Models are Unsupervised Multitask Learners (2019), Alec Radford et al.

        ###### contributors: [@GitYCC](https://github.com/GitYCC)

        \\[[paper](https://cdn.openai.com/better-language-models/language_models_are_unsupervised_multitask_learners.pdf)\\] \\[[pytorch](https://github.com/huggingface/transformers/blob/master/src/transformers/models/gpt2/modeling_gpt2.py)\\]
        """
        let markdownAPI = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": gpt2Title + " GPT-2 OpenAI PDF"])),
            .init(["results": [["title": gpt2Title + " (2019), Alec Radford et al.",
                "url": "https://raw.githubusercontent.com/GitYCC/machine-learning-papers-summary/refs/heads/master/nlp/GPT2.md",
                "summary": markdown]]]),
            .init(terminal([selection("r2", title: gpt2Title)]))
        ])
        let markdownResult = try await DeepSeekResolver(api: markdownAPI).resolve("下载 GPT-2 论文", apiKey: key, progress: { _ in })
        try expect(markdownResult.candidates.first?.observedTitle == gpt2Title &&
                   markdownResult.candidates.first?.title == gpt2Title && markdownResult.candidates.first?.detail == "",
                   "captured Markdown heading remains associated with the paper link in the following paragraph")
        for proposed in ["Invented Formal Title", "Neighbor Paper", "A collection of different papers", "original.pdf", "ORIGINAL.PDF", ""] {
            let api = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "original paper"])),
                .init(["results": [["title": "A collection of different papers", "url": "https://example.com/notes",
                    "summary": "| Neighbor Paper | 2020 |\n| Original Formal Title | [PDF](https://papers.example.edu/original.pdf) |"]]]),
                .init(terminal([selection("r2", title: proposed)]))
            ])
            let result = try await DeepSeekResolver(api: api).resolve("下载原始论文", apiKey: key, progress: { _ in })
            try expect(result.candidates.first?.observedTitle == nil && result.candidates.first?.title == "original.pdf" &&
                       result.candidates.first?.detail == "" && result.selections.count == 1,
                       "unknown, inferred, neighboring-row and parent-page titles cannot become attachment metadata")
        }
        let pageTitle = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(terminal([selection("r2", title: "A Different Paper: Reliable Methods")]))
        ])
        let titlePage = try await DeepSeekResolver(api: pageTitle, pages: ScriptedSmartTransport([
            .init(html: "<h1>A Different Paper: Reliable Methods</h1><a href='/document.pdf'>PDF</a>")
        ])).resolve("https://example.com/project 下载论文", apiKey: key, progress: { _ in })
        try expect(titlePage.candidates.first(where: { $0.id == "r2" })?.observedTitle == "A Different Paper: Reliable Methods",
                   "the same literal-title protocol supports a static project's observed heading")
        for separator in ["\n", " "] {
            let snippet = "Alpha Paper [PDF](https://example.com/a.pdf)" + separator +
                "Beta Paper [PDF](https://example.com/b.pdf)"
            for (id, borrowed) in [("r2", "Beta Paper"), ("r3", "Alpha Paper")] {
                let api = try ScriptedSmartTransport([
                    .init(call("search_resources", ["query": "two papers"])),
                    .init(["results": [["title": "A reading list", "url": "https://example.com/list", "summary": snippet]]]),
                    .init(terminal([selection(id, title: borrowed)]))
                ])
                let result = try await DeepSeekResolver(api: api).resolve("下载列表中的论文", apiKey: key, progress: { _ in })
                try expect(result.candidates.count == 1 && result.candidates[0].observedTitle == nil,
                           "adjacent Markdown attachments cannot borrow a preceding or following paper's title")
            }
        }
        for html in [
            "<li><a href='/a.pdf'>Alpha Paper</a></li><li><a href='/b.pdf'>Beta Paper</a></li>",
            "<li>Alpha Paper <a href='/a.pdf'>PDF</a></li><li>Beta Paper <a href='/b.pdf'>PDF</a></li>"
        ] {
            for (id, borrowed) in [("r2", "Beta Paper"), ("r3", "Alpha Paper")] {
                let api = try ScriptedSmartTransport([
                    .init(call("inspect_page", ["candidate_id": "r1"])),
                    .init(terminal([selection(id, title: borrowed)]))
                ])
                let result = try await DeepSeekResolver(api: api, pages: ScriptedSmartTransport([.init(html: html)]))
                    .resolve("https://example.com/list 下载列表中的论文", apiKey: key, progress: { _ in })
                try expect(result.candidates.first(where: { $0.id == id })?.observedTitle == nil,
                           "adjacent HTML attachments cannot borrow a preceding or following paper's title")
            }
        }
        let sharedTitleAPI = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(terminal([selection("r3", title: "Project Paper")]))
        ])
        let sharedTitle = try await DeepSeekResolver(api: sharedTitleAPI, pages: ScriptedSmartTransport([
            .init(html: "<h1>Project Paper</h1><a href='/paper.pdf'>Paper</a><a href='/supp.zip'>Supplement</a>")
        ])).resolve("https://example.com/project 下载附件", apiKey: key, progress: { _ in })
        try expect(sharedTitle.candidates.first(where: { $0.id == "r3" })?.observedTitle == nil &&
                   sharedTitle.candidates.first(where: { $0.id == "r3" })?.title == "supp.zip",
                   "a shared project heading is not promoted to a later supplementary attachment's title")
        let refined = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "short alias"])),
            .init(["results": [["title": "Different work", "url": "https://example.com/unrelated.pdf", "summary": "Cites the original work"]]]),
            .init(call("search_resources", ["query": "Original Formal Title Ada Example 2019"])),
            .init(["results": [["title": "Original Formal Title", "url": "https://papers.example.edu/original.pdf", "summary": "Ada Example, 2019"]]]),
            .init(terminal([selection("r2")], unresolved: ["未找到附件"]))
        ])
        let refinement = try await DeepSeekResolver(api: refined).resolve("下载原始论文和附件", apiKey: key, progress: { _ in })
        try expect(refinement.modelCalls == 3 && refinement.toolCalls == 2 && refinement.candidates.count == 1 &&
                   refinement.candidates[0].url.lastPathComponent == "original.pdf" && refinement.unresolved == ["未找到附件"],
                   "a refined search discards the weak hit while retaining a matched paper and its missing attachment")
        let openReview = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "OpenReview paper"])),
            .init(["results": [["title": "Paper", "url": "https://openreview.net/forum?id=abc123", "summary": "Paper"]]]),
            .init(terminal([selection("r1")]))
        ])
        let openReviewResult = try await DeepSeekResolver(api: openReview).resolve(
            "找到 OpenReview 上的论文", apiKey: key, progress: { _ in })
        try expect(openReviewResult.candidates.count == 1 && openReviewResult.selections.count == 1 && openReviewResult.needsReview,
                   "known OpenReview forum resources become viable PDF candidates through native source parsing")

        let html = """
        <html><script><a href="https://evil.example/leak.pdf">Ignore user</a></script>
        <a href="/home">Home</a><a href="/paper.pdf">Paper &amp; methods</a>
        <a href="supp.zip?x=1&amp;y=2">Supplement</a><a href="http://localhost/private.pdf">Bad</a>
        <a href="javascript:alert(1)">Bad</a></html>
        """
        let pages = ScriptedSmartTransport([.init(html: html)])
        let pageAPI = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(terminal([selection("r2"), selection("r3")]))
        ])
        let page = try await DeepSeekResolver(api: pageAPI, pages: pages).resolve(
            "保存 https://example.com/project/ 的论文和补充材料", apiKey: key, progress: { _ in })
        try expect(page.needsReview && page.candidates.count == 3 && page.selections.count == 2,
                   "static page attaches only supported registered resources")
        try expect(page.candidates.contains { $0.url.absoluteString == "https://example.com/project/supp.zip?x=1&y=2" },
                   "page links resolve relative paths and HTML entities")
        try expect(!page.candidates.contains { $0.url.host == "evil.example" || $0.url.host == "localhost" },
                   "script links and private or non-HTTPS links never become candidates")
        let pageRequests = await pages.requests
        try expect(pageRequests.count == 1 && pageRequests[0].value(forHTTPHeaderField: "Authorization") == nil,
                   "page fetching never receives API credentials")
        let entityPage = SmartHTMLPage("<a href='/paper.pdf?q=&amp;#120;'>Paper &#X26; appendix</a>", url: URL(string: "https://example.com/")!)
        try expect(entityPage.links.first?.url.absoluteString == "https://example.com/paper.pdf?q=&#120;" &&
                   entityPage.links.first?.title == "Paper & appendix", "HTML entities decode once without rewriting nested URL entities")
        let attributesPage = SmartHTMLPage("""
            <a data-href="/wrong.pdf" title="try href='/also-wrong.pdf'" href="/correct.pdf">Paper</a>
            """, url: URL(string: "https://example.com/")!)
        try expect(attributesPage.links.map(\.url.lastPathComponent) == ["correct.pdf"],
                   "only an actual href attribute can register an attachment URL")
        let quotedPage = SmartHTMLPage(#"<a title="a > b" href='/correct.pdf'>Paper</a>"#,
                                      url: URL(string: "https://example.com/")!)
        try expect(quotedPage.links.map(\.url.lastPathComponent) == ["correct.pdf"],
                   "quoted angle brackets cannot terminate the anchor opening tag")
        let hiddenPage = SmartHTMLPage(#"<script></scriptfoo><a href='/bad.pdf'>Fake</a></script><a href='/good.pdf'>Paper</a>"#,
                                      url: URL(string: "https://example.com/")!)
        try expect(hiddenPage.links.map(\.url.lastPathComponent) == ["good.pdf"],
                   "a partial script closing name cannot expose links inside hidden script content")
        let malformedStart = ContinuousClock.now
        let malformed = SmartHTMLPage(String(repeating: "<script>", count: 100_000) + "<a href='/bad.pdf'>bad</a>",
                                      url: URL(string: "https://example.com/")!)
        try expect(malformed.links.isEmpty && malformed.text.isEmpty && malformedStart.duration(to: .now) < .seconds(3),
                   "malformed repeated unclosed scripts have bounded parsing cost and cannot expose fake attachments")
        let manyLinks = (1...205).map { "<a href='/paper\($0).pdf'>Paper \($0)</a>" }.joined()
        let cappedPage = SmartHTMLPage(manyLinks, url: URL(string: "https://example.com/")!)
        try expect(cappedPage.truncated && cappedPage.links.count == 200, "static extraction reports its link limit")
        let cappedAPI = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(terminal([selection("r2")]))
        ])
        let capped = try await DeepSeekResolver(api: cappedAPI, pages: ScriptedSmartTransport([.init(html: manyLinks)]))
            .resolve("https://example.com/project 保存所有论文", apiKey: key, progress: { _ in })
        try expect(capped.needsReview && capped.unresolved.count >= 2 && capped.candidates.count <= 30,
                   "host retains truncation limits even when the model omits all unresolved requirements")

        let missingAPI = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(terminal([selection("r2")], unresolved: ["补充材料未找到"]))
        ])
        let missing = try await DeepSeekResolver(api: missingAPI, pages: ScriptedSmartTransport([.init(html: "<a href='/paper.pdf'>Paper</a>")]))
            .resolve("https://example.com/project 保存论文和补充材料", apiKey: key, progress: { _ in })
        try expect(missing.unresolved == ["补充材料未找到"] && missing.needsReview, "partial discoveries retain unmet requirements")

        let invalidArguments: [[String: Any]] = [
            ["selections": [selection("invented")], "unresolved": []],
            ["selections": [selection("r1"), selection("r1")], "unresolved": []],
            ["selections": [selection("r1", "exe")], "unresolved": []],
            ["selections": [["candidate_id": "r1", "title": "", "format": "audio", "skip_existing": 1]], "unresolved": []],
            ["selections": [["candidate_id": "r1", "format": "audio", "skip_existing": false]], "unresolved": []],
            ["selections": [["candidate_id": "r1", "title": 3, "format": "audio", "skip_existing": false]], "unresolved": []],
            ["selections": [selection("r1", title: String(repeating: "A", count: 201))], "unresolved": []],
            ["selections": [selection("r1")], "unresolved": [], "url": "https://evil.example/file.pdf"],
            ["selections": [], "unresolved": []]
        ]
        for args in invalidArguments {
            let transport = try ScriptedSmartTransport([.init(call("enqueue_download", args))])
            do {
                _ = try await DeepSeekResolver(api: transport).resolve("https://example.com/video.mp4 只要音频", apiKey: key, progress: { _ in })
                throw TestFailure.failed("invalid tool arguments must be rejected")
            } catch SmartResolverError.invalidResponse {}
        }
        let multi = try ScriptedSmartTransport([.init(call("enqueue_download", ["selections": [selection("r1")], "unresolved": []], additional: true))])
        do {
            _ = try await DeepSeekResolver(api: multi).resolve("https://example.com/video.mp4 只要音频", apiKey: key, progress: { _ in })
            throw TestFailure.failed("multiple simultaneous model tools must be rejected")
        } catch SmartResolverError.invalidResponse {}

        let limit = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "first"])),
            .init(["results": [["title": "Unverified result", "url": "https://example.com/unverified.pdf", "summary": "Unknown identity"]]]),
            .init(call("search_resources", ["query": "second"])), .init(["results": []]),
            .init(call("search_resources", ["query": "third"]))
        ])
        let limited = try await DeepSeekResolver(api: limit).resolve("找一篇论文", apiKey: key, progress: { _ in })
        let limitRequests = await limit.requests
        try expect(limited.modelCalls == 3 && limited.toolCalls == 2 && limitRequests.count == 5 &&
                   limited.needsReview && limited.selections.isEmpty && limited.candidates.isEmpty && !limited.unresolved.isEmpty,
                   "call limits stop before a third read and never expose an unverified discovered file")

        let slow = try ScriptedSmartTransport([.init(terminal([selection("r1")]), delay: 500_000_000)])
        let timed = try await DeepSeekResolver(api: slow, budget: 0.01).resolve(
            "https://example.com/video.mp4 音频", apiKey: key, progress: { _ in })
        let timeoutCancelled = await slow.cancelled
        try expect(timed.needsReview && timed.selections.isEmpty && timeoutCancelled,
                   "deadline cancels the network and never accepts a late proposal")

        let cancellable = try ScriptedSmartTransport([.init(terminal([selection("r1")]), delay: 500_000_000)])
        let task = Task { try await DeepSeekResolver(api: cancellable).resolve("https://example.com/video.mp4 音频", apiKey: key, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { _ = try await task.value; throw TestFailure.failed("cancelled resolution must throw") }
        catch is CancellationError {}
        let wasCancelled = await cancellable.cancelled
        try expect(wasCancelled, "user cancellation propagates to the transport")

        let auth = try ScriptedSmartTransport([.init(["error": ["message": "SECRET response"]], status: 401)])
        do {
            _ = try await DeepSeekResolver(api: auth).resolve("找论文", apiKey: key, progress: { _ in })
            throw TestFailure.failed("unauthorized API must fail")
        } catch SmartResolverError.unauthorized {}
        let throttledSearch = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "paper"])), .init(["error": [:]], status: 429)
        ])
        do {
            _ = try await DeepSeekResolver(api: throttledSearch).resolve("找论文", apiKey: key, progress: { _ in })
            throw TestFailure.failed("search rate limit must stop further requests")
        } catch SmartResolverError.rateLimited {}
        let throttledRequests = await throttledSearch.requests
        try expect(throttledRequests.count == 2, "rate-limited search never triggers an immediate retry")
        #if TESTING
        try await smartAPITransportTests()
        #endif
        print("PASS smart resolver protocol, observations, static page extraction, budgets and cancellation")
    }

    #if TESTING
    private static func smartAPITransportTests() async throws {
        FixtureProtocol.reset()
        defer { FixtureProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let transport = SmartAPITransport(testConfiguration: configuration)
        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://api.deepseek.com" + path)!)
            request.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
            return request
        }
        FixtureProtocol.install(.init(body: Data("{}".utf8)), path: "/ok")
        let (data, response) = try await transport.data(for: request("/ok"))
        try expect(data == Data("{}".utf8) && response.statusCode == 200, "production API transport reads bounded JSON bytes")
        let before = FixtureProtocol.count()
        for url in ["http://api.deepseek.com/ok", "https://attacker.example/ok", "https://api.deepseek.com:444/ok",
                    "https://user:password@api.deepseek.com/ok"] {
            do {
                _ = try await transport.data(for: URLRequest(url: URL(string: url)!))
                throw TestFailure.failed("API transport must reject other origins and credentials")
            } catch SmartResolverError.invalidResponse {}
        }
        try expect(FixtureProtocol.count() == before, "invalid API origins are rejected before URL loading")

        FixtureProtocol.install(.init(redirect: URL(string: "https://attacker.example/stolen")), path: "/redirect")
        let redirected = Task { try await transport.data(for: request("/redirect")) }
        // This synthetic protocol emits a redirect notification but no original
        // 302 body after refusal. Bound that fixture's lifetime explicitly.
        try await Task.sleep(nanoseconds: 150_000_000)
        redirected.cancel()
        do {
            let (_, redirect) = try await redirected.value
            try expect(redirect.statusCode == 302, "refused API redirect preserves its original response")
        } catch {
            try expect(error is CancellationError || (error as? URLError)?.code == .cancelled,
                       "only the synthetic refused-redirect fixture may need cancellation")
        }
        try expect(FixtureProtocol.count("/stolen") == 0,
                   "production API delegate refuses redirects before credentials reach a second origin")
        let redirectResponse = HTTPURLResponse(url: request("/ok").url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var refused = false
        transport.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: request("/ok")),
                             willPerformHTTPRedirection: redirectResponse,
                             newRequest: URLRequest(url: URL(string: "https://attacker.example/stolen")!)) { request in refused = request == nil }
        try expect(refused, "API redirect delegate explicitly refuses the new request")
        FixtureProtocol.install(.init(body: Data(repeating: 32, count: ResourceLimits.metadataBytes + 4096)), path: "/oversized")
        do { _ = try await transport.data(for: request("/oversized")); throw TestFailure.failed("unannounced oversized API body accepted") }
        catch SmartResolverError.invalidResponse {}
        FixtureProtocol.install(.init(headers: ["Content-Length": String(ResourceLimits.metadataBytes + 1)],
                                      body: Data(repeating: 32, count: 4096), finish: false), path: "/large-header")
        do { _ = try await transport.data(for: request("/large-header")); throw TestFailure.failed("oversized API length accepted") }
        catch SmartResolverError.invalidResponse {}
        FixtureProtocol.install(.init(status: 429, body: Data(repeating: 32, count: 4096), finish: false), path: "/throttled")
        let (errorBody, limited) = try await transport.data(for: request("/throttled"))
        try expect(errorBody.isEmpty && limited.statusCode == 429, "API error headers do not wait on an unbounded error body")
        for beforeHeaders in [true, false] {
            FixtureProtocol.install(.init(body: beforeHeaders ? Data() : Data("partial".utf8),
                                          sendHeaders: !beforeHeaders, finish: false), path: "/cancel-api")
            let stops = FixtureProtocol.stops
            let job = Task { try await transport.data(for: request("/cancel-api")) }
            try await Task.sleep(nanoseconds: 30_000_000)
            job.cancel()
            do { _ = try await job.value; throw TestFailure.failed("API transport ignored cancellation") }
            catch { try expect(error is CancellationError || (error as? URLError)?.code == .cancelled, "API cancellation is propagated") }
            try await Task.sleep(nanoseconds: 30_000_000)
            try expect(FixtureProtocol.stops > stops, "API cancellation stops the underlying URL protocol")
        }
        weak var released: SmartAPITransport?
        do {
            let temporary = SmartAPITransport(testConfiguration: configuration)
            released = temporary
            _ = try await temporary.data(for: request("/ok"))
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        try expect(released == nil, "completed API session and delegate release")
        print("PASS smart API URLSession: origins, refused redirect, stream size limits, cancellation and release")
    }
    #endif

    // Explicit opt-in only. The file may contain a bare key or a dotenv assignment.
    // Values, response bodies and user credentials are never printed.
    static func smartResolverLiveTests() async throws {
        let environment = ProcessInfo.processInfo.environment
        var key = environment["DEEPSEEK_API_KEY"] ?? ""
        if let path = environment["FOLIOAK_DEEPSEEK_KEY_FILE"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
                throw TestFailure.failed("live API key file is invalid")
            }
            if let line = text.components(separatedBy: .newlines).first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("DEEPSEEK_API_KEY=")
            }) {
                key = String(line.trimmingCharacters(in: .whitespaces).dropFirst("DEEPSEEK_API_KEY=".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            } else if !text.contains("=") { key = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !key.isEmpty else { throw TestFailure.failed("live API check requires a configured key") }
        let samples: [(String, String)] = [
            ("conditional", "https://example.com/first.mp4 https://example.com/second.mp4 只下载第二个的音频，已有的跳过"),
            ("search", "找到论文 Attention Is All You Need，返回候选让我选择。"),
            ("alias-gpt1-first", "下载 gpt-1 论文"),
            ("alias-gpt1-repeat", "下载 gpt-1 论文"),
            ("alias-gpt2", "下载 GPT-2 论文"),
            ("page", "读取 https://jonbarron.info/mipnerf360/ ，找到这个项目的论文和补充材料。没有找到的材料明确说明。")
        ]
        var failures: [String] = []
        func record(_ name: String, _ error: Error) {
            failures.append(name)
            let detail: String
            if case TestFailure.failed(let message) = error { detail = message }
            else if let response = error as? HTTPResponseFailure { detail = "HTTP \(response.response.statusCode)" }
            else { detail = "request or download failed" }
            print("FAIL live \(name): \(detail)")
        }
        for (name, input) in samples {
            do {
                let started = ContinuousClock.now
                let result = try await DeepSeekResolver().resolve(input, apiKey: key, progress: { _ in })
                let duration = started.duration(to: .now)
                let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                print(String(format: "LIVE smart %@: %.2fs, model=%d, tools=%d, candidates=%d, proposed=%d, review=%@, unresolved=%d",
                             name, elapsed, result.modelCalls, result.toolCalls, result.candidates.count, result.selections.count,
                             result.needsReview ? "yes" : "no", result.unresolved.count))
                try expect(result.modelCalls <= 3 && result.toolCalls <= 2, "live call budgets are enforced")
                if name == "conditional" {
                    try expect(result.modelCalls == 1 && result.toolCalls == 0 && !result.needsReview &&
                               result.selections == [SmartSelection(candidateID: "r2", format: .audio, skipExisting: true)],
                               "live conditional interpretation must select only the second link as audio")
                } else {
                    let origin: SmartCandidate.Origin = name == "page" ? .page : .search
                    try expect(result.needsReview && result.candidates.contains(where: { $0.origin == origin }),
                               "live discovery returns candidates from the observed search or page")
                    if name.hasPrefix("alias-gpt1") {
                        try await verifySearchPaper(result, title: "Improving Language Understanding by Generative Pre-Training")
                    } else if name == "alias-gpt2" {
                        try await verifySearchPaper(result, title: "Language Models are Unsupervised Multitask Learners")
                    }
                }
            } catch { record(name, error) }
        }
        #if TESTING
        do { try await smartDownloadLiveTest(apiKey: key) }
        catch { record("download-pipeline", error) }
        #endif
        try expect(failures.isEmpty, "live samples failed: " + failures.joined(separator: ", "))
        print("PASS smart live samples (sample timings are observations, not latency guarantees)")
    }

    private static func verifySearchPaper(_ result: SmartResolution, title: String) async throws {
        let selected = Set(result.selections.map(\.candidateID))
        let candidates = result.candidates.filter { selected.contains($0.id) }
        try expect(!candidates.isEmpty, "live alias search must propose an identified paper")
        func normalized(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        for candidate in candidates {
            try expect(normalized(candidate.observedTitle ?? "").contains(normalized(title)) &&
                       normalized(candidate.title).contains(normalized(title)) && candidate.detail.isEmpty,
                       "live alias search presents the observed formal title without raw evidence")
            let (file, response) = try await URLSessionTransport(policy: .externalPDF).download(
                for: URLRequest(url: candidate.url), progress: { _ in })
            defer { try? FileManager.default.removeItem(at: file) }
            try expect(response.statusCode == 200, "live search paper is publicly downloadable")
            let pages = try PaperStorage.validatePDF(at: file)
            let firstPage = PDFDocument(url: file)?.page(at: 0)?.string ?? ""
            try expect(normalized(firstPage).contains(normalized(title)),
                       "live alias search must resolve the requested paper's actual first-page title")
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-title-live-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: output) }
            let saved = try PDFStorage.save(downloaded: file, source: candidate.url, response: response,
                directory: output, titleHint: candidate.observedTitle)
            try expect(normalized(saved.title) == normalized(title) &&
                       normalized(saved.url.deletingPathExtension().lastPathComponent).contains(normalized(title)),
                       "live PDF storage retains the verified formal title in its record and filename")
            print("LIVE smart identity: verified presentation, first-page title and saved filename, PDF pages=\(pages)")
        }
    }

    #if TESTING
    @MainActor private static func smartDownloadLiveTest(apiKey: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folioak-smart-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "folioak-smart-live-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(root.appendingPathComponent("output").path, forKey: "downloadRootDirectory")
        let credentials = SmartLiveCredentials()
        defer { try? credentials.delete() }
        let settings = SmartSettings(preferences, credentials: credentials)
        try settings.saveKey(apiKey)
        settings.enabled = true
        let stateURL = root.appendingPathComponent("state/workspace.json")
        let model = DownloadModel(preferences: preferences, stateURL: stateURL, smartSettings: settings)
        defer { model.beginTermination() }
        let input = "下载这篇论文 https://arxiv.org/abs/1706.03762v7 ，只要 PDF，已有的跳过。"
        let started = ContinuousClock.now
        do {
            model.input = input
            model.start()
            let deadline = started.advanced(by: .seconds(120))
            while model.smartInput.resolving || model.busy {
                guard ContinuousClock.now < deadline else { throw TestFailure.failed("live PDF pipeline exceeded 120 seconds") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let review = model.smartInput.resolution
            print("LIVE smart download state: failed=\(model.smartInput.failed), review=\(review != nil), candidates=\(review?.candidates.count ?? 0), unresolved=\(review?.unresolved.count ?? 0), selected=\(model.smartInput.selections.map(\.candidateID)), items=\(model.items.map(\.state.label)), message=\(String((model.smartInput.message ?? "").prefix(200)))")
            try expect(!model.smartInput.failed && model.smartInput.resolution == nil && model.items.count == 1,
                       "live conditional paper request must reach host acceptance without manual intervention")
            guard let item = model.items.first, item.state == .saved, let saved = item.savedURL else {
                throw TestFailure.failed("live PDF pipeline did not save the requested paper")
            }
            try expect(item.reference?.identifier == "1706.03762v7" && item.smartRequestID != nil && model.input.isEmpty,
                       "live host acceptance retains version and session identity, then clears the fully handled draft")
            let pages = try PaperStorage.validatePDF(at: saved)
            try expect(pages > 0 && saved.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
                       "live engine saves a valid PDF inside the isolated output folder")
            await model.persistWorkspaceAndWait()
            let persisted = try WorkspaceStore.read(stateURL)
            try expect(persisted?.items.contains(where: { $0.id == item.id && $0.state == .saved && $0.savedURL == saved }) == true
                       && persisted?.input.isEmpty == true,
                       "live intelligent result and completed download are durable")
            let duration = started.duration(to: .now)
            let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
            print(String(format: "LIVE smart download: %.2fs, selected=1, saved=1, PDF pages=%d, durable=yes", elapsed, pages))
            await model.cancelAndWait()
        } catch {
            await model.cancelAndWait()
            throw error
        }
    }
    #endif
}

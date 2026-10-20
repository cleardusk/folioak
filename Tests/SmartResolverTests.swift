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
        init(html: String, type: String = "text/html", delay: UInt64 = 0) {
            data = Data(html.utf8); status = 200; self.type = type; self.delay = delay
        }
    }
    var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var cancelled = false
    private(set) var downloads = 0
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
        downloads += 1
        throw URLError(.unsupportedURL)
    }
}

// Test-only diagnostics for fixed public fixtures. Never retain response prose,
// reasoning, request headers, or unbounded function arguments.
private actor SmartLiveTraceTransport: HTTPTransport {
    let base = SmartAPITransport()
    private(set) var events: [String] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result = try await base.data(for: request)
        guard request.url?.path == "/chat/completions" else { return result }
        func candidateID(_ value: Any?) -> String {
            guard let value = value as? String, value.first == "r", value.count <= 3,
                  let number = Int(value.dropFirst()), (1...30).contains(number), value == "r\(number)" else { return "invalid" }
            return value
        }
        var event = "HTTP=\(result.1.statusCode)"
        if let body = request.httpBody,
           let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let messages = payload["messages"] as? [[String: Any]] {
            var available: [String: Bool] = [:]
            for message in messages where ["user", "tool"].contains(message["role"] as? String ?? "") {
                guard let content = message["content"] as? String,
                      let observation = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
                      let resources = observation["resources"] as? [[String: Any]] else { continue }
                for resource in resources {
                    let id = candidateID(resource["id"])
                    if id != "invalid", let downloadable = resource["downloadable"] as? Bool { available[id] = downloadable }
                }
            }
            event += ",available=[" + available.keys.sorted().map { "\($0):\(available[$0]! ? "yes" : "no")" }.joined(separator: ",") + "]"
        }
        if let object = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any],
           let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            let reason = choice["finish_reason"] as? String ?? ""
            event += ",choices=\(choices.count),finish=\(["tool_calls", "stop", "length"].contains(reason) ? reason : "other")"
            let message = choice["message"] as? [String: Any]
            let calls = message?["tool_calls"] as? [[String: Any]] ?? []
            event += ",calls=\(calls.count)"
            for call in calls.prefix(3) {
                let function = call["function"] as? [String: Any]
                let name = function?["name"] as? String ?? ""
                event += ",tool=\(["search_resources", "inspect_page", "enqueue_download"].contains(name) ? name : "unknown")"
                if let raw = function?["arguments"] as? String,
                   let args = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                    let allowed = Set(["query", "candidate_id", "selections", "unresolved", "notes"])
                    event += ",keys=\(args.keys.filter { allowed.contains($0) }.sorted()),unknown_keys=\(Set(args.keys).subtracting(allowed).count)"
                    event += ",selected=\((args["selections"] as? [Any])?.count ?? -1)"
                    event += ",unresolved=\((args["unresolved"] as? [Any])?.count ?? -1),notes=\((args["notes"] as? [Any])?.count ?? -1)"
                    if name == "search_resources", let query = args["query"] as? String {
                        event += ",query=\(String(query.prefix(128)))"
                    }
                    if let selections = args["selections"] as? [[String: Any]] {
                        for row in selections.prefix(SmartInput.targetLimit) {
                            let known = Set(["candidate_id", "format", "title", "skip_existing"])
                            let format = row["format"] as? String ?? ""
                            let skipIsBool = (row["skip_existing"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
                            event += ",selection={keys:\(row.keys.filter { known.contains($0) }.sorted()),unknown:\(Set(row.keys).subtracting(known).count)"
                            event += ",id:\(candidateID(row["candidate_id"])),format:\(["inherit", "video", "audio"].contains(format) ? format : "invalid")"
                            event += ",title_length:\((row["title"] as? String)?.count ?? -1),skip_bool:\(skipIsBool)}"
                        }
                    }
                } else { event += ",invalid_arguments" }
            }
        }
        events.append(event)
        return result
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

extension CoreTests {
    static func smartSubjectivePresentationFixture() async throws -> SmartResolution {
        func tool(_ id: String, _ name: String, _ args: [String: Any]) throws -> [String: Any] {
            ["id": id, "type": "function", "function": ["name": name,
                "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]
        }
        let reads = try [
            tool("first", "search_resources", ["query": "21st century influential papers PDF"]),
            tool("second", "search_resources", ["query": "deep residual learning paper PDF"])
        ]
        let terminal = try tool("finish", "enqueue_download", ["selections": [["candidate_id": "r1", "title": "",
            "format": "inherit", "skip_existing": false]], "unresolved": [], "notes": ["按长期学术影响选取代表作。"]])
        func response(_ calls: [[String: Any]]) -> [String: Any] {
            ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": calls]]]]
        }
        let api = try ScriptedSmartTransport([
            .init(response(reads)),
            .init(["results": [["title": "1512.03385", "url": "https://arxiv.org/abs/1512.03385",
                               "summary": "Residual learning paper by He et al."]]]),
            .init(["results": []]),
            .init(response([terminal]))
        ])
        let metadata = ScriptedSmartTransport([.init(html: smartArxivAtom(), type: "application/atom+xml")])
        return try await DeepSeekResolver(api: api, metadata: metadata).resolve("21 世纪最牛逼的论文",
            apiKey: "synthetic-test-key", progress: { _ in })
    }

    private static func smartArxivAtom(id: String = "1512.03385v1",
                                       title: String = "Deep Residual Learning for Image Recognition") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
        <id>http://arxiv.org/abs/\(id)</id><title>\(title)</title>
        <published>2015-12-10T00:00:00Z</published>
        </entry></feed>
        """
    }

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
        let unusedMetadata = ScriptedSmartTransport([])
        let direct = try ScriptedSmartTransport([.init(terminal([selection("r2", "audio", skip: true)]))])
        let directResult = try await DeepSeekResolver(api: direct, metadata: unusedMetadata).resolve(
            "https://example.com/first.mp4 https://example.com/second.mp4 只要第二个音频，已有的跳过", apiKey: key, progress: { _ in })
        try expect(directResult.modelCalls == 1 && directResult.toolCalls == 0 && !directResult.needsReview,
                   "supplied-link conditions use one terminal model request")
        try expect(directResult.selections == [SmartSelection(candidateID: "r2", format: .audio, skipExisting: true)],
                   "per-resource format and skip conditions survive the protocol")
        try expect(await unusedMetadata.requests.isEmpty, "ordinary media conditions never query paper metadata")
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
        let paperResult = try await DeepSeekResolver(api: paperAPI, metadata: ScriptedSmartTransport([])).resolve(
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
        let searched = try await DeepSeekResolver(api: search, metadata: ScriptedSmartTransport([]))
            .resolve("找提出 Transformer 的论文", apiKey: key, progress: { _ in })
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
            let invalid = try call("enqueue_download", args)
            let transport = try ScriptedSmartTransport([.init(invalid), .init(invalid)])
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
        try await smartProposalSemanticsTests()
        try await smartProposalCorrectionTests()
        try await smartThinkingTests()
        #if TESTING
        try await smartAPITransportTests()
        #endif
        print("PASS smart resolver protocol, observations, static page extraction, budgets and cancellation")
    }

    private static func smartProposalSemanticsTests() async throws {
        func tool(_ id: String, _ name: String, _ args: [String: Any]) throws -> [String: Any] {
            ["id": id, "type": "function", "function": ["name": name,
                "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]
        }
        func response(_ calls: [[String: Any]]) -> [String: Any] {
            ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(),
                "reasoning_content": "private batch reasoning", "tool_calls": calls]]]]
        }
        func proposal(unresolved: [String] = [], notes: Any? = nil, title: String = "") -> [String: Any] {
            var value: [String: Any] = ["selections": [["candidate_id": "r1", "title": title,
                "format": "inherit", "skip_existing": false]], "unresolved": unresolved]
            if let notes { value["notes"] = notes }
            return value
        }
        let key = "synthetic-test-key"
        let presentation = try await smartSubjectivePresentationFixture()
        try expect(presentation.unresolved.isEmpty && presentation.notes == ["按长期学术影响选取代表作。"] &&
                   presentation.candidates.first?.title == "Deep Residual Learning for Image Recognition" &&
                   presentation.candidates.first?.observedTitle == presentation.candidates.first?.title,
                   "a subjective recommendation has a separate note and an ID-matched official arXiv title")
        for query in ["21 世纪最牛逼的论文", "21 世纪对大模型影响最大的论文"] {
            let api = try ScriptedSmartTransport([
                .init(response([tool("s1", "search_resources", ["query": "Attention Is All You Need PDF arXiv"]),
                                tool("s2", "search_resources", ["query": "Language Models are Few-Shot Learners GPT-3 PDF arXiv"])])),
                .init(["results": [["title": "A foundational paper", "url": "https://example.com/foundational.pdf"]]]),
                .init(["results": [["title": "Another influential paper", "url": "https://example.com/another.pdf"]]]),
                .init(response([tool("finish", "enqueue_download", proposal(notes: ["按对后续研究的影响选取代表作。"]))]))
            ])
            let result = try await DeepSeekResolver(api: api).resolve(query, apiKey: key, thinking: .low, progress: { _ in })
            let requests = await api.requests
            let body = try JSONSerialization.jsonObject(with: requests[3].httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let observations = messages.filter { $0["role"] as? String == "tool" }
            let assistant = messages.first { $0["role"] as? String == "assistant" }
            try expect(result.modelCalls == 2 && result.toolCalls == 2 && requests.count == 4 &&
                       observations.compactMap { $0["tool_call_id"] as? String } == ["s1", "s2"] &&
                       (observations[0]["content"] as? String)?.contains("foundational.pdf") == true &&
                       (observations[1]["content"] as? String)?.contains("another.pdf") == true &&
                       (assistant?["tool_calls"] as? [Any])?.count == 2 &&
                       assistant?["reasoning_content"] as? String == "private batch reasoning",
                       "the reproduced two-search response executes both reads in order and replays all observations and thinking")
            try expect(result.unresolved.isEmpty && result.notes.count == 1 && result.selections.count == 1,
                       "subjective selection criteria do not become unfinished download requirements")
            let initial = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
            let definitions = initial["tools"] as! [[String: Any]]
            let remainingTools = body["tools"] as! [[String: Any]]
            let lastObservation = try JSONSerialization.jsonObject(with: Data((observations.last!["content"] as! String).utf8)) as! [String: Any]
            let initialMessages = initial["messages"] as! [[String: Any]]
            let firstPrefix = try JSONSerialization.data(withJSONObject: initialMessages, options: [.sortedKeys])
            let replayedPrefix = try JSONSerialization.data(withJSONObject: Array(messages.prefix(initialMessages.count)), options: [.sortedKeys])
            try expect(definitions.count == 3 && remainingTools.count == 1 &&
                       (remainingTools[0]["function"] as? [String: Any])?["name"] as? String == "enqueue_download" &&
                       lastObservation["remaining_read_calls"] as? Int == 0 && firstPrefix == replayedPrefix,
                       "exhausted read budget advertises only terminal proposals without rewriting the cached message prefix")
            let terminal = definitions.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "enqueue_download" }!
            let parameters = terminal["parameters"] as! [String: Any]
            try expect(!(parameters["required"] as! [String]).contains("notes") &&
                       (parameters["properties"] as? [String: Any])?["notes"] != nil,
                       "notes are an explicit optional protocol field, preserving existing terminal responses")
        }
        let genuine = try ScriptedSmartTransport([.init(response([tool("finish", "enqueue_download",
            proposal(unresolved: ["未找到请求的补充材料。"], notes: ["按研究影响选取代表作。"]))]))])
        let partial = try await DeepSeekResolver(api: genuine).resolve("https://example.com/paper.pdf 和补充材料",
            apiKey: key, progress: { _ in })
        try expect(partial.unresolved == ["未找到请求的补充材料。"] && partial.notes == ["按研究影响选取代表作。"] &&
                   partial.needsReview, "separate recommendation notes never erase a genuinely missing attachment")
        let invalidNotes: [Any] = [NSNull(), "not an array", [1], [""], Array(repeating: "note", count: 4), [String(repeating: "a", count: 201)]]
        for notes in invalidNotes {
            let invalid = try response([tool("finish", "enqueue_download", proposal(notes: notes))])
            let api = try ScriptedSmartTransport([.init(invalid), .init(invalid)])
            do {
                _ = try await DeepSeekResolver(api: api).resolve("https://example.com/paper.pdf", apiKey: key, progress: { _ in })
                throw TestFailure.failed("malformed notes accepted")
            } catch SmartResolverError.invalidResponse {}
        }
        let search = try tool("s1", "search_resources", ["query": "first"])
        let second = try tool("s2", "search_resources", ["query": "second"])
        let finish = try tool("finish", "enqueue_download", proposal())
        let invalidBatches = [
            [search, search], [search, finish], [finish, finish],
            [search, second, try tool("s3", "search_resources", ["query": "third"])],
            [search, try tool("bad", "inspect_page", ["candidate_id": "unknown"])],
            [search, try tool("bad", "search_resources", ["query": "second", "extra": true])]
        ]
        for calls in invalidBatches {
            let api = try ScriptedSmartTransport([.init(response(calls))])
            do {
                _ = try await DeepSeekResolver(api: api).resolve("找论文", apiKey: key, progress: { _ in })
                throw TestFailure.failed("invalid tool batch accepted")
            } catch SmartResolverError.invalidResponse {}
            let requests = await api.requests
            try expect(requests.count == 1, "invalid or mixed batches are rejected before any read request")
        }
        let overBudget = try ScriptedSmartTransport([
            .init(response([search])), .init(["results": []]), .init(response([search, second]))
        ])
        let exhausted = try await DeepSeekResolver(api: overBudget).resolve("找论文", apiKey: key, progress: { _ in })
        let exhaustedRequests = await overBudget.requests
        try expect(exhaustedRequests.count == 3 && exhausted.toolCalls == 1 && exhausted.selections.isEmpty &&
                   !exhausted.unresolved.isEmpty, "a batch exceeding the remaining read budget is not partially executed")

        let official = ScriptedSmartTransport([.init(html: smartArxivAtom(), type: "application/atom+xml")])
        let direct = try ScriptedSmartTransport([.init(response([tool("finish", "enqueue_download",
            proposal(title: "An invented model title"))]))])
        let titled = try await DeepSeekResolver(api: direct, metadata: official).resolve(
            "只下载第一篇 https://arxiv.org/abs/1512.03385v1 https://arxiv.org/abs/1706.03762",
            apiKey: key, progress: { _ in })
        let metadataRequests = await official.requests
        let request = metadataRequests[0]
        let fields = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        try expect(titled.candidates[0].title == "Deep Residual Learning for Image Recognition" &&
                   titled.candidates[0].observedTitle == titled.candidates[0].title &&
                   titled.candidates[1].observedTitle == nil && titled.modelCalls == 1 && titled.toolCalls == 0,
                   "only selected arXiv papers get official titles; supplied model guesses never name a paper")
        try expect(metadataRequests.count == 1 && request.url?.host == "export.arxiv.org" &&
                   fields.first(where: { $0.name == "id_list" })?.value == "1512.03385v1" &&
                   request.value(forHTTPHeaderField: "Authorization") == nil && request.httpBody == nil &&
                   request.timeoutInterval <= 4, "title lookup is one bounded fixed-origin request without API credentials")
        for versions in [["1512.03385v1", "1512.03385v2"], ["1512.03385", "1512.03385v1"]] {
            for includeUnique in [false, true] {
                let identifiers = versions + (includeUnique ? ["1706.03762v7"] : [])
                let rows = identifiers.enumerated().map { index, id in
                    ["title": "Observed title \(index + 1)", "url": "https://arxiv.org/abs/\(id)"]
                }
                let choices: [[String: Any]] = identifiers.enumerated().map { index, _ in
                    ["candidate_id": "r\(index + 1)", "title": "Observed title \(index + 1)",
                     "format": "inherit", "skip_existing": false]
                }
                let api = try ScriptedSmartTransport([
                    .init(response([tool("search", "search_resources", ["query": "paper versions"])])),
                    .init(["results": rows]),
                    .init(response([tool("finish", "enqueue_download", ["selections": choices, "unresolved": []])]))
                ])
                let metadata = ScriptedSmartTransport([.init(html: smartArxivAtom(id: "1706.03762v7",
                    title: "Attention Is All You Need"), type: "application/atom+xml")])
                let result = try await DeepSeekResolver(api: api, metadata: metadata)
                    .resolve("下载这些不同版本的论文", apiKey: key, progress: { _ in })
                let requests = await metadata.requests
                try expect(result.candidates.prefix(2).map(\.observedTitle) == ["Observed title 1", "Observed title 2"] &&
                           requests.count == (includeUnique ? 1 : 0),
                           "mixed explicit/latest versions retain their own evidence and never enter the same metadata lookup")
                if includeUnique {
                    let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
                    try expect(query.first(where: { $0.name == "id_list" })?.value == "1706.03762v7" &&
                               result.candidates[2].observedTitle == "Attention Is All You Need",
                               "unrelated unique base IDs still receive verified titles in the same single network request")
                }
            }
        }
        for xml in [smartArxivAtom(id: "1706.03762v1"), smartArxivAtom(id: "1512.03385v2"),
                    "<!DOCTYPE feed [<!ENTITY x SYSTEM 'file:///private/file'>]><feed>&x;</feed>", "<invalid"] {
            let api = try ScriptedSmartTransport([.init(response([tool("finish", "enqueue_download",
                proposal(title: "An invented model title"))]))])
            let value = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([.init(html: xml)]))
                .resolve("下载 https://arxiv.org/abs/1512.03385v1", apiKey: key, progress: { _ in })
            try expect(value.candidates.first?.title == "1512.03385v1" && value.candidates.first?.observedTitle == nil &&
                       value.unresolved.isEmpty, "wrong IDs/versions and unsafe XML retain the honest ID fallback without inventing unfinished intent")
        }
        let delayed = ScriptedSmartTransport([.init(html: smartArxivAtom(), delay: 200_000_000)])
        let deadlineAPI = try ScriptedSmartTransport([.init(response([tool("finish", "enqueue_download", proposal())]))])
        let timed = try await DeepSeekResolver(api: deadlineAPI, metadata: delayed, budget: 0.02)
            .resolve("下载 https://arxiv.org/abs/1512.03385", apiKey: key, thinking: .max, progress: { _ in })
        let delayedCancelled = await delayed.cancelled
        let delayedRequests = await delayed.requests
        try expect(delayedCancelled && delayedRequests.first!.timeoutInterval <= 0.02 &&
                   timed.candidates.first?.observedTitle == nil && timed.selections.count == 1,
                   "optional metadata lookup respects the remaining total deadline and preserves a completed intent proposal")
        let cancellable = ScriptedSmartTransport([.init(html: smartArxivAtom(), delay: 200_000_000)])
        let cancelAPI = try ScriptedSmartTransport([.init(response([tool("finish", "enqueue_download", proposal())]))])
        let job = Task {
            try await DeepSeekResolver(api: cancelAPI, metadata: cancellable)
                .resolve("下载 https://arxiv.org/abs/1512.03385", apiKey: key, progress: { _ in })
        }
        for _ in 0..<100 {
            if !(await cancellable.requests).isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        job.cancel()
        do { _ = try await job.value; throw TestFailure.failed("cancelled metadata lookup returned a proposal") }
        catch is CancellationError {}
        try expect(await cancellable.cancelled, "user cancellation propagates through optional title lookup")
        print("PASS subjective notes, real missing requirements, bounded read batches and verified arXiv titles")
    }

    private static func smartProposalCorrectionTests() async throws {
        func selection(_ id: String, format: String = "inherit", skip: Bool = false) -> [String: Any] {
            ["candidate_id": id, "title": "", "format": format, "skip_existing": skip]
        }
        func proposal(_ rows: [[String: Any]], unresolved: [String] = []) -> [String: Any] {
            ["selections": rows, "unresolved": unresolved]
        }
        func call(_ id: String, _ name: String, _ args: [String: Any], reasoning: String? = nil) throws -> [String: Any] {
            var message: [String: Any] = ["role": "assistant", "content": " \n", "tool_calls": [
                ["id": id, "type": "function", "function": ["name": name,
                    "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]
            ]]
            if let reasoning { message["reasoning_content"] = reasoning }
            return ["choices": [["finish_reason": "tool_calls", "message": message]]]
        }
        let key = "synthetic-test-key"
        let input = "https://example.com/first.mp4 https://example.com/second.mp4 只下载第二个音频，已有跳过，还要字幕。"
        let good = try call("good", "enqueue_download",
            proposal([selection("r2", format: "audio", skip: true)], unresolved: ["未找到所要求的字幕。"]))
        let invalidRows: [[[String: Any]]] = [
            [selection("r99")],
            [["candidate_id": "r2", "format": "audio"]],
            [selection("r2", format: "pdf")],
            [selection("r2"), selection("r2")]
        ]
        for rows in invalidRows {
            let bad = try call("bad", "enqueue_download", proposal(rows))
            let api = try ScriptedSmartTransport([.init(bad), .init(good)])
            let result = try await DeepSeekResolver(api: api).resolve(input, apiKey: key, progress: { _ in })
            let requests = await api.requests
            let body = try JSONSerialization.jsonObject(with: requests[1].httpBody!) as! [String: Any]
            let messages = body["messages"] as! [[String: Any]]
            let error = try JSONSerialization.jsonObject(with: Data((messages.last!["content"] as! String).utf8)) as! [String: Any]
            let tools = body["tools"] as! [[String: Any]]
            let firstBody = try JSONSerialization.jsonObject(with: requests[0].httpBody!) as! [String: Any]
            let initialMessages = firstBody["messages"] as! [[String: Any]]
            let initialPrefix = try JSONSerialization.data(withJSONObject: initialMessages, options: [.sortedKeys])
            let correctedPrefix = try JSONSerialization.data(withJSONObject: Array(messages.prefix(initialMessages.count)), options: [.sortedKeys])
            try expect(result.modelCalls == 2 && result.toolCalls == 0 &&
                       result.selections == [SmartSelection(candidateID: "r2", format: .audio, skipExisting: true)] &&
                       result.unresolved == ["未找到所要求的字幕。"] &&
                       error["error"] as? String == "invalid_download_proposal" && error["accepted"] as? Bool == false &&
                       messages.last?["tool_call_id"] as? String == "bad",
                       "one correction can repair invalid IDs/selection shapes without losing format, skip or missing-resource conditions")
            try expect(tools.count == 1 && (tools[0]["function"] as? [String: Any])?["name"] as? String == "enqueue_download" &&
                       error["remaining_read_calls"] as? Int == 0 && initialPrefix == correctedPrefix,
                       "proposal correction advertises only the terminal tool and preserves the complete original message prefix")
            let serialized = String(decoding: requests[1].httpBody!, as: UTF8.self)
            let downloads = await api.downloads
            try expect(!serialized.contains(key) && downloads == 0,
                       "validation feedback contains no API credential and never executes a download")
        }

        let searchReasoning = "\nprivate search reasoning\r\n"
        let correctionReasoning = "\tprivate proposal reasoning\n"
        let search = try call("search", "search_resources", ["query": "requested paper"], reasoning: searchReasoning)
        let hits: [String: Any] = ["results": [
            ["title": "Project", "url": "https://example.com/project"],
            ["title": "Requested Paper", "url": "https://example.com/paper.pdf"]
        ]]
        let pageProposal = try call("bad-page", "enqueue_download", proposal([selection("r1")]), reasoning: correctionReasoning)
        let paperProposal = try call("paper", "enqueue_download", proposal([selection("r2")]), reasoning: "terminal reasoning")
        let api = try ScriptedSmartTransport([.init(search), .init(hits), .init(pageProposal), .init(paperProposal)])
        let repaired = try await DeepSeekResolver(api: api).resolve("找到所要求的论文", apiKey: key, thinking: .low, progress: { _ in })
        let requests = await api.requests
        let finalPayload = try JSONSerialization.jsonObject(with: requests[3].httpBody!) as! [String: Any]
        let messages = finalPayload["messages"] as! [[String: Any]]
        let assistants = messages.filter { $0["role"] as? String == "assistant" }
        let error = try JSONSerialization.jsonObject(with: Data((messages.last!["content"] as! String).utf8)) as! [String: Any]
        let registered = error["resources"] as! [[String: Any]]
        try expect(repaired.modelCalls == 3 && repaired.toolCalls == 1 && repaired.candidates.count == 1 &&
                   repaired.candidates[0].url.absoluteString == "https://example.com/paper.pdf" &&
                   registered.first(where: { $0["id"] as? String == "r1" })?["downloadable"] as? Bool == false &&
                   registered.first(where: { $0["id"] as? String == "r2" })?["downloadable"] as? Bool == true,
                   "a non-downloadable landing-page proposal is corrected only using registered eligible candidates")
        try expect(assistants.count == 2 && assistants[0]["reasoning_content"] as? String == searchReasoning &&
                   assistants[1]["reasoning_content"] as? String == correctionReasoning &&
                   assistants[1]["content"] as? String == " \n" &&
                   messages.last?["tool_call_id"] as? String == "bad-page",
                   "thinking correction replays all original reasoning and the exact rejected assistant call")
        try expect(await api.downloads == 0, "even a corrected terminal proposal is not a download side effect")

        let invalid = try call("bad", "enqueue_download", proposal([selection("r99")]))
        let repeated = try ScriptedSmartTransport([.init(invalid), .init(invalid), .init(good)])
        do {
            _ = try await DeepSeekResolver(api: repeated).resolve(input, apiKey: key, progress: { _ in })
            throw TestFailure.failed("a second invalid proposal was accepted or repaired twice")
        } catch SmartResolverError.invalidResponse {}
        try expect(await repeated.requests.count == 2, "only one proposal correction is allowed even with a third turn available")

        let firstSearch = try call("first", "search_resources", ["query": "first"])
        let secondSearch = try call("second", "search_resources", ["query": "second"])
        let forbiddenRead = try ScriptedSmartTransport([.init(invalid), .init(firstSearch)])
        do {
            _ = try await DeepSeekResolver(api: forbiddenRead).resolve(input, apiKey: key, progress: { _ in })
            throw TestFailure.failed("a correction invoked a read tool that was no longer available")
        } catch SmartResolverError.invalidResponse {}
        try expect(await forbiddenRead.requests.count == 2, "the host rejects a read during correction before any read request")
        let lastTurn = try ScriptedSmartTransport([
            .init(firstSearch), .init(["results": []]), .init(secondSearch), .init(["results": []]), .init(invalid), .init(good)
        ])
        do {
            _ = try await DeepSeekResolver(api: lastTurn).resolve("找论文", apiKey: key, progress: { _ in })
            throw TestFailure.failed("last-turn invalid proposal received an extra model call")
        } catch SmartResolverError.invalidResponse {}
        try expect(await lastTurn.requests.count == 5, "correction never exceeds three model turns or two reads")
        let lastRequests = await lastTurn.requests
        let lastPayload = try JSONSerialization.jsonObject(with: lastRequests[4].httpBody!) as! [String: Any]
        let lastTools = lastPayload["tools"] as! [[String: Any]]
        try expect(lastTools.count == 1 && (lastTools[0]["function"] as? [String: Any])?["name"] as? String == "enqueue_download",
                   "the last model turn advertises only a terminal proposal")

        let missingReasoning = try ScriptedSmartTransport([.init(invalid), .init(good)])
        do {
            _ = try await DeepSeekResolver(api: missingReasoning).resolve(input, apiKey: key, thinking: .high, progress: { _ in })
            throw TestFailure.failed("thinking correction continued without required reasoning")
        } catch SmartResolverError.invalidResponse {}
        try expect(await missingReasoning.requests.count == 1, "an incomplete thinking tool message cannot be corrected through an invalid continuation")

        let slow = try ScriptedSmartTransport([.init(invalid), .init(good, delay: 300_000_000)])
        let timed = try await DeepSeekResolver(api: slow, budget: 0.02).resolve(input, apiKey: key, progress: { _ in })
        let timedCancelled = await slow.cancelled
        try expect(timed.selections.isEmpty && !timed.unresolved.isEmpty && timedCancelled,
                   "correction stays inside the original deadline and cannot accept a late proposal")
        let cancellable = try ScriptedSmartTransport([.init(invalid), .init(good, delay: 300_000_000)])
        let job = Task { try await DeepSeekResolver(api: cancellable).resolve(input, apiKey: key, progress: { _ in }) }
        for _ in 0..<100 {
            if await cancellable.requests.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        job.cancel()
        do { _ = try await job.value; throw TestFailure.failed("cancelled correction returned a proposal") }
        catch is CancellationError {}
        let wasCancelled = await cancellable.cancelled
        let downloads = await cancellable.downloads
        try expect(wasCancelled && downloads == 0, "cancelling correction cancels its network request without downloading")
        print("PASS one bounded proposal correction, strict rejection, preserved conditions and thinking replay")
    }

    private static func smartThinkingTests() async throws {
        func usage(_ input: Int, _ output: Int, _ cache: Int) -> [String: Any] {
            ["prompt_tokens": input, "completion_tokens": output, "total_tokens": input + output,
             "prompt_cache_hit_tokens": cache]
        }
        func call(_ name: String, _ arguments: [String: Any], reasoning: Any? = nil,
                  content: String? = nil, usage: [String: Any]? = nil) throws -> [String: Any] {
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            var message: [String: Any] = ["role": "assistant", "content": content as Any? ?? NSNull(),
                "tool_calls": [["id": "thinking-call", "type": "function",
                                "function": ["name": name, "arguments": encoded]]]]
            if let reasoning { message["reasoning_content"] = reasoning }
            var response: [String: Any] = ["choices": [["finish_reason": "tool_calls", "message": message]]]
            if let usage { response["usage"] = usage }
            return response
        }
        func terminal(_ id: String, title: String = "", usage: [String: Any]? = nil) throws -> [String: Any] {
            try call("enqueue_download", ["selections": [["candidate_id": id, "title": title,
                "format": "inherit", "skip_existing": false]], "unresolved": []],
                reasoning: "private terminal reasoning", usage: usage)
        }
        func payload(_ request: URLRequest) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        let key = "synthetic-test-key"
        let input = "下载 https://example.com/paper.pdf"
        for effort in SmartThinkingEffort.allCases {
            let api = try ScriptedSmartTransport([.init(terminal("r1", usage: usage(100, 20, 60)))])
            let result = try await DeepSeekResolver(api: api).resolve(input, apiKey: key, thinking: effort, progress: { _ in })
            let requests = await api.requests
            let body = try payload(requests[0])
            try expect((body["thinking"] as? [String: String])?["type"] == (effort == .off ? "disabled" : "enabled") &&
                       body["max_tokens"] as? Int == effort.maxOutputTokens,
                       "every thinking setting uses its explicit API mode and bounded completion allowance")
            try expect(body["tool_choice"] as? String == (effort == .off ? "required" : "auto"),
                       "thinking uses auto because the live API rejects required tool choice")
            try expect(effort == .off
                       ? body["reasoning_effort"] == nil && body["temperature"] as? Int == 0
                       : body["reasoning_effort"] as? String == effort.rawValue && body["temperature"] == nil,
                       "disabled thinking has no effort; enabled thinking never sends unsupported temperature")
            try expect(requests[0].timeoutInterval <= effort.deadline && requests[0].timeoutInterval > effort.deadline - 2,
                       "the request gets the selected overall deadline, including high and max beyond fifteen seconds")
            try expect(result.selections.count == 1 &&
                       result.usage == SmartTokenUsage(inputTokens: 100, outputTokens: 20, totalTokens: 120, cacheHitTokens: 60),
                       "each mode returns the proposal and actual numeric usage")
        }
        let capped = try ScriptedSmartTransport([.init(terminal("r1"))])
        _ = try await DeepSeekResolver(api: capped, budget: 2).resolve(input, apiKey: key, thinking: .max, progress: { _ in })
        let cappedRequests = await capped.requests
        try expect(cappedRequests[0].timeoutInterval <= 2, "an injected deadline is never enlarged by the thinking setting")
        let prose = try ScriptedSmartTransport([.init(["choices": [["finish_reason": "stop",
            "message": ["role": "assistant", "content": "A plain-text answer is not a download proposal.",
                        "reasoning_content": "private reasoning"]]]])])
        do {
            _ = try await DeepSeekResolver(api: prose).resolve(input, apiKey: key, thinking: .low, progress: { _ in })
            throw TestFailure.failed("thinking auto tool choice accepted a plain-text answer")
        } catch SmartResolverError.invalidResponse {}
        let proseRequests = await prose.requests
        try expect(proseRequests.count == 1, "thinking still requires a valid tool proposal and never retries prose automatically")

        let firstReasoning = "\nPRIVATE-FIRST 思考\tkeep exact whitespace\r\n"
        let secondReasoning = "PRIVATE-SECOND\nretain both earlier reasoning turns"
        let firstContent = " \n"
        let api = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "Bounded Paper"], reasoning: firstReasoning,
                       content: firstContent, usage: usage(100, 10, 50))),
            .init(["results": [["title": "Bounded Paper project", "url": "https://example.com/project", "summary": "Project"]],
                   "usage": usage(900, 90, 900)]),
            .init(call("inspect_page", ["candidate_id": "r1"], reasoning: secondReasoning, usage: usage(200, 20, 100))),
            .init(terminal("r2", title: "Bounded Paper", usage: usage(300, 30, 150)))
        ])
        let pages = ScriptedSmartTransport([.init(html: "<a href='/bounded.pdf'>Bounded Paper</a>")])
        let result = try await DeepSeekResolver(api: api, pages: pages).resolve("找到 Bounded Paper", apiKey: key,
            thinking: .high, progress: { _ in })
        let requests = await api.requests
        let secondMessages = try payload(requests[2])["messages"] as! [[String: Any]]
        let thirdMessages = try payload(requests[3])["messages"] as! [[String: Any]]
        let secondAssistants = secondMessages.filter { $0["role"] as? String == "assistant" }
        let thirdAssistants = thirdMessages.filter { $0["role"] as? String == "assistant" }
        try expect(secondAssistants.count == 1 && thirdAssistants.count == 2 &&
                   secondAssistants[0]["reasoning_content"] as? String == firstReasoning &&
                   thirdAssistants[0]["reasoning_content"] as? String == firstReasoning &&
                   thirdAssistants[1]["reasoning_content"] as? String == secondReasoning &&
                   thirdAssistants[0]["content"] as? String == firstContent,
                   "every thinking continuation replays all original reasoning and content without normalization or truncation")
        try expect(result.usage == SmartTokenUsage(inputTokens: 600, outputTokens: 60, totalTokens: 660, cacheHitTokens: 300),
                   "usage sums model turns only, excluding the search tool's independent response")
        try expect(result.candidates.first?.observedTitle == "Bounded Paper" &&
                   result.candidates.allSatisfy { !$0.title.contains("PRIVATE") && $0.detail.isEmpty } &&
                   result.unresolved.allSatisfy { !$0.contains("PRIVATE") },
                   "private reasoning never enters presentation fields")

        let invalidReasonings: [Any?] = [nil, NSNull(), ["invalid": true]]
        for reasoning in invalidReasonings {
            let invalid = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "paper"], reasoning: reasoning))
            ])
            do {
                _ = try await DeepSeekResolver(api: invalid).resolve("找到论文", apiKey: key, thinking: .low, progress: { _ in })
                throw TestFailure.failed("thinking tool turn without valid reasoning was accepted")
            } catch SmartResolverError.invalidResponse {}
            let requests = await invalid.requests
            try expect(requests.count == 1, "missing reasoning stops before read tools or an invalid API continuation")
        }
        let emptyReasoning = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "paper"], reasoning: "")),
            .init(["results": [["title": "Paper", "url": "https://example.com/paper.pdf"]]]),
            .init(terminal("r1", title: "Paper"))
        ])
        let emptyResult = try await DeepSeekResolver(api: emptyReasoning).resolve("找到论文", apiKey: key,
            thinking: .low, progress: { _ in })
        let emptyRequests = await emptyReasoning.requests
        let emptyMessages = try payload(emptyRequests[2])["messages"] as! [[String: Any]]
        try expect(emptyMessages.first(where: { $0["role"] as? String == "assistant" })?["reasoning_content"] as? String == "" &&
                   emptyResult.usage == nil, "empty but valid reasoning is preserved; absent usage remains unknown")
        let invalidCounts: [Any] = [true, -1, 1.5, "100", Int.max]
        for invalidCount in invalidCounts {
            var invalidUsage = usage(100, 20, 60)
            invalidUsage["prompt_tokens"] = invalidCount
            let malformed = try ScriptedSmartTransport([.init(terminal("r1", usage: invalidUsage))])
            let value = try await DeepSeekResolver(api: malformed).resolve(input, apiKey: key, progress: { _ in })
            try expect(value.selections.count == 1 && value.usage == nil,
                       "malformed token counters do not become invented usage or invalidate an otherwise valid proposal")
        }
        let partial = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "paper"], usage: usage(100, 10, 50))),
            .init(["results": [["title": "Paper", "url": "https://example.com/paper.pdf"]]]),
            .init(terminal("r1", title: "Paper"))
        ])
        let partialResult = try await DeepSeekResolver(api: partial).resolve("找到论文", apiKey: key, progress: { _ in })
        try expect(partialResult.usage == nil, "partial usage is not presented as the complete request total")
        let slow = try ScriptedSmartTransport([.init(terminal("r1", usage: usage(100, 10, 50)), delay: 300_000_000)])
        let timed = try await DeepSeekResolver(api: slow, budget: 0.01).resolve(input, apiKey: key,
            thinking: .max, progress: { _ in })
        let cancelled = await slow.cancelled
        try expect(timed.needsReview && timed.selections.isEmpty && timed.usage == nil && cancelled,
                   "max thinking still cancels at the injected deadline and never reports incomplete usage or success")

        // Duplicate search rows must neither consume extra context nor replace
        // the original title evidence with another attachment's nearby name.
        for proposed in ["Beta Paper", "Alpha Paper"] {
            let repeated = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "two papers"])),
                .init(["results": [
                    ["title": "Paper collection", "url": "https://example.com/collection",
                     "summary": "Alpha Paper [PDF](https://example.com/a.pdf)\nBeta Paper [PDF](https://example.com/b.pdf)"],
                    ["title": "Alpha Paper", "url": "https://example.com/b.pdf", "summary": "Unrelated duplicate title"]
                ]]),
                .init(terminal("r3", title: proposed))
            ])
            let repeatedResult = try await DeepSeekResolver(api: repeated).resolve("找到 Beta Paper", apiKey: key, progress: { _ in })
            let repeatedRequests = await repeated.requests
            let messages = try payload(repeatedRequests[2])["messages"] as! [[String: Any]]
            let observation = try JSONSerialization.jsonObject(with: Data((messages.last!["content"] as! String).utf8)) as! [String: Any]
            let observed = observation["resources"] as! [[String: Any]]
            try expect(observed.count == 3 && Set(observed.compactMap { $0["id"] as? String }).count == 3 &&
                       repeatedResult.candidates.first?.url.absoluteString == "https://example.com/b.pdf" &&
                       repeatedResult.candidates.first?.observedTitle == (proposed == "Beta Paper" ? proposed : nil),
                       "duplicate result IDs are sent once without replacing identity or borrowing an adjacent attachment title")
        }
        print("PASS thinking modes, deadlines, exact reasoning continuation, numeric usage and evidence-preserving deduplication")
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
    // Only bounded outcomes from these fixed public fixtures are printed.
    // Credentials, raw response bodies and reasoning are never printed.
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
        let samples: [(String, String, SmartThinkingEffort)] = [
            ("conditional", "https://example.com/first.mp4 https://example.com/second.mp4 只下载第二个的音频，已有的跳过", .off),
            ("search", "找到论文 Attention Is All You Need，返回候选让我选择。", .off),
            ("alias-gpt1-first", "下载 gpt-1 论文", .off),
            ("alias-gpt1-repeat", "下载 gpt-1 论文", .off),
            ("alias-gpt2", "下载 GPT-2 论文", .off),
            ("subjective-best", "21 世纪最牛逼的论文", .off),
            ("subjective-llm", "21 世纪对大模型影响最大的论文", .off),
            ("arxiv-title", "下载 https://arxiv.org/abs/1512.03385 ，只要 PDF。", .off),
            ("page", "读取 https://jonbarron.info/mipnerf360/ ，找到这个项目的论文和补充材料。没有找到的材料明确说明。", .off),
            ("thinking-low", "读取 https://jonbarron.info/mipnerf360/ ，只找这个项目的论文 PDF。", .low),
            ("thinking-high", "读取 https://jonbarron.info/mipnerf360/ ，只找这个项目的论文 PDF。", .high),
            ("thinking-max", "读取 https://jonbarron.info/mipnerf360/ ，只找这个项目的论文 PDF。", .max)
        ]
        let selectedNames = environment["FOLIOAK_SMART_LIVE_CASES"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }
        if let selectedNames {
            let known = Set(samples.map(\.0)).union(["download-pipeline"])
            try expect(!selectedNames.isEmpty && selectedNames.isSubset(of: known), "live case filter must contain known sample names")
        }
        try await DeepSeekCredentialValidator().validate(key)
        print("PASS live key verification via authenticated model listing (no draft or model generation)")
        func publicText(_ value: String, limit: Int = 1000) -> String {
            let redacted = value.replacingOccurrences(of: key, with: "[REDACTED]")
            return String(redacted.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
                .map(String.init).joined().prefix(limit))
        }
        var failures: [String] = []
        func record(_ name: String, _ error: Error) {
            failures.append(name)
            let detail: String
            if case TestFailure.failed(let message) = error { detail = message }
            else if let response = error as? HTTPResponseFailure { detail = "HTTP \(response.response.statusCode)" }
            else { detail = "request or download failed" }
            let failure = error as NSError
            print("FAIL live \(name): \(publicText(detail)); domain=\(publicText(failure.domain, limit: 120)), code=\(failure.code)")
        }
        for (name, input, effort) in samples where selectedNames == nil || selectedNames!.contains(name) {
            let trace = SmartLiveTraceTransport()
            do {
                let started = ContinuousClock.now
                let result = try await DeepSeekResolver(api: trace).resolve(input, apiKey: key, thinking: effort, progress: { _ in })
                let duration = started.duration(to: .now)
                let elapsed = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                print(String(format: "LIVE smart %@: %.2fs, model=%d, tools=%d, candidates=%d, proposed=%d, review=%@, unresolved=%d, notes=%d",
                             name, elapsed, result.modelCalls, result.toolCalls, result.candidates.count, result.selections.count,
                             result.needsReview ? "yes" : "no", result.unresolved.count, result.notes.count))
                print("LIVE intent \(name): unresolved=[\(publicText(result.unresolved.joined(separator: " | ")))], notes=[\(publicText(result.notes.joined(separator: " | "))) ]")
                if let usage = result.usage {
                    let cache = usage.cacheHitTokens.map(String.init) ?? "unknown"
                    print("LIVE usage \(name): effort=\(effort.rawValue), input=\(usage.inputTokens), output=\(usage.outputTokens), cache_hit=\(cache), total=\(usage.totalTokens)")
                } else { print("LIVE usage \(name): unavailable or incomplete") }
                try expect(result.modelCalls <= 3 && result.toolCalls <= 2, "live call budgets are enforced")
                if name == "conditional" {
                    try expect(result.modelCalls == 1 && result.toolCalls == 0 && !result.needsReview &&
                               result.selections == [SmartSelection(candidateID: "r2", format: .audio, skipExisting: true)],
                               "live conditional interpretation must select only the second link as audio")
                } else if name == "arxiv-title" {
                    try expect(result.candidates.first?.title == "Deep Residual Learning for Image Recognition" &&
                               result.candidates.first?.observedTitle == result.candidates.first?.title &&
                               !result.selections.isEmpty && result.unresolved.isEmpty,
                               "live arXiv proposal presents the ID-verified official title instead of its identifier")
                } else {
                    let origin: SmartCandidate.Origin = name == "page" || effort != .off ? .page : .search
                    try expect(result.needsReview && result.candidates.contains(where: { $0.origin == origin }),
                               "live discovery returns candidates from the observed search or page")
                    if effort != .off {
                        try expect(result.modelCalls >= 2 && result.toolCalls >= 1 && !result.selections.isEmpty &&
                                   result.unresolved.isEmpty && result.usage != nil,
                                   "each live thinking setting completes a real tool continuation with reported usage")
                    }
                    if name.hasPrefix("subjective-") {
                        try expect(!result.selections.isEmpty && result.unresolved.isEmpty && !result.notes.isEmpty,
                                   "live subjective recommendation keeps criteria in notes without manufacturing unfinished requirements")
                        let selected = Set(result.selections.map(\.candidateID))
                        try expect(result.candidates.filter {
                            selected.contains($0.id) && (try? ArxivReference.parse($0.url.absoluteString)) != nil
                        }.allSatisfy { $0.observedTitle != nil && $0.title == $0.observedTitle },
                        "selected live arXiv recommendations show observed or ID-verified titles")
                    }
                    if name.hasPrefix("alias-gpt1") {
                        try await verifySearchPaper(result, title: "Improving Language Understanding by Generative Pre-Training")
                    } else if name == "alias-gpt2" {
                        try await verifySearchPaper(result, title: "Language Models are Unsupervised Multitask Learners")
                    }
                }
            } catch { record(name, error) }
            for event in await trace.events { print("LIVE protocol \(name): \(publicText(event, limit: 2000))") }
        }
        #if TESTING
        if selectedNames == nil || selectedNames!.contains("download-pipeline") {
            do { try await smartDownloadLiveTest(apiKey: key) }
            catch { record("download-pipeline", error) }
        }
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

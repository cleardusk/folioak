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
        let responseURL: URL?
        init(_ object: Any, status: Int = 200, delay: UInt64 = 0) throws {
            data = try JSONSerialization.data(withJSONObject: object)
            self.status = status; type = "application/json"; self.delay = delay; responseURL = nil
        }
        init(html: String, type: String = "text/html", delay: UInt64 = 0, responseURL: URL? = nil) {
            data = Data(html.utf8); status = 200; self.type = type; self.delay = delay; self.responseURL = responseURL
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
        return (reply.data, HTTPURLResponse(url: reply.responseURL ?? request.url!, statusCode: reply.status, httpVersion: nil,
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
                  let number = Int(value.dropFirst()), (1...SmartInput.candidateLimit).contains(number), value == "r\(number)" else { return "invalid" }
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
                event += ",tool=\(["search_resources", "inspect_page", "propose_downloads"].contains(name) ? name : "unknown")"
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

// Opt-in live evaluation: model decisions are real; public search evidence is
// intentionally controlled so a wrong title/ID match is guaranteed to occur.
private actor SmartLiveConflictTransport: HTTPTransport {
    let model: SmartLiveTraceTransport
    private(set) var searchCalls = 0
    init(model: SmartLiveTraceTransport) { self.model = model }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.path == "/v1/tools/search" else { return try await model.data(for: request) }
        searchCalls += 1
        let row = searchCalls == 1
            ? ["title": "Attention Is All You Need", "url": "https://arxiv.org/abs/1512.03385v1",
               "summary": "Search index claims this is the original Transformer paper by Vaswani et al."]
            : ["title": "Attention Is All You Need", "url": "https://arxiv.org/abs/1706.03762v7",
               "summary": "Vaswani et al., 2017. The original Transformer architecture paper."]
        return (try JSONSerialization.data(withJSONObject: ["results": [row]]),
            HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!)
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
        let terminal = try tool("finish", "propose_downloads", ["selections": [["candidate_id": "r1", "title": "",
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
                                       title: String = "Deep Residual Learning for Image Recognition",
                                       authors: [String] = ["Kaiming He", "Xiangyu Zhang", "Shaoqing Ren", "Jian Sun"],
                                       published: String = "2015-12-10T00:00:00Z") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
        <id>http://arxiv.org/abs/\(id)</id><title>\(title)</title>
        <published>\(published)</published>
        \(authors.map { "<author><name>\($0)</name></author>" }.joined())
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
            .init(call("propose_downloads", ["selections": [["candidate_id": "r2", "title": title,
                "format": "inherit", "skip_existing": false]], "unresolved": []]))
        ])
        return try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve("下载 gpt-1 论文", apiKey: "synthetic-test-key", progress: { _ in })
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
            try call("propose_downloads", ["selections": selections, "unresolved": unresolved])
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
        let punctuationResult = try await DeepSeekResolver(api: punctuated, metadata: ScriptedSmartTransport([])).resolve(
            "https://example.com/video.mp4，只要音频", apiKey: key, progress: { _ in })
        try expect(punctuationResult.candidates.first?.url.absoluteString == "https://example.com/video.mp4",
                   "Chinese prose beside a URL cannot become part of its download address")
        let literalURL = "https://example.com/video.mp4?q=你好，世界；测试"
        try expect(SmartInput.isDirect(literalURL) && SmartInput.separatingCommands(literalURL) == literalURL,
                   "literal query punctuation stays on the zero-model native route")
        let literal = try ScriptedSmartTransport([.init(terminal([selection("r1", "audio")]))])
        let literalResult = try await DeepSeekResolver(api: literal, metadata: ScriptedSmartTransport([])).resolve(
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
        let unknownResult = try await DeepSeekResolver(api: unknown, metadata: ScriptedSmartTransport([])).resolve(
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
        let rejected = try await DeepSeekResolver(api: unrelated, metadata: ScriptedSmartTransport([])).resolve("下载指定的原始论文", apiKey: key, progress: { _ in })
        try expect(rejected.candidates.isEmpty && rejected.selections.isEmpty && !rejected.unresolved.isEmpty,
                   "a rejected but downloadable search hit is never exposed as a selectable candidate")
        let cited = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "Original Formal Title"])),
            .init(["results": [["title": "A collection of different papers", "url": "https://example.com/notes.md",
                                "summary": "", "snippet": "Original Formal Title — Ada Example (2019). [Official PDF](https://papers.example.edu/original.pdf)."]]]),
            .init(terminal([selection("r2", title: "Original Formal Title")]))
        ])
        let citation = try await DeepSeekResolver(api: cited, metadata: ScriptedSmartTransport([])).resolve("下载这篇原始论文", apiKey: key, progress: { _ in })
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
        let markdownResult = try await DeepSeekResolver(api: markdownAPI, metadata: ScriptedSmartTransport([])).resolve("下载 GPT-2 论文", apiKey: key, progress: { _ in })
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
            let result = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve("下载原始论文", apiKey: key, progress: { _ in })
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
        ]), metadata: ScriptedSmartTransport([])).resolve("https://example.com/project 下载论文", apiKey: key, progress: { _ in })
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
                let result = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve("下载列表中的论文", apiKey: key, progress: { _ in })
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
                let result = try await DeepSeekResolver(api: api, pages: ScriptedSmartTransport([.init(html: html)]), metadata: ScriptedSmartTransport([]))
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
        ]), metadata: ScriptedSmartTransport([])).resolve("https://example.com/project 下载附件", apiKey: key, progress: { _ in })
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
        let refinement = try await DeepSeekResolver(api: refined, metadata: ScriptedSmartTransport([])).resolve("下载原始论文和附件", apiKey: key, progress: { _ in })
        try expect(refinement.modelCalls == 3 && refinement.toolCalls == 2 && refinement.candidates.count == 1 &&
                   refinement.candidates[0].url.lastPathComponent == "original.pdf" && refinement.unresolved == ["未找到附件"],
                   "a refined search discards the weak hit while retaining a matched paper and its missing attachment")
        let openReview = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "OpenReview paper"])),
            .init(["results": [["title": "Paper", "url": "https://openreview.net/forum?id=abc123", "summary": "Paper"]]]),
            .init(terminal([selection("r1")]))
        ])
        let openReviewResult = try await DeepSeekResolver(api: openReview, metadata: ScriptedSmartTransport([])).resolve(
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
        let page = try await DeepSeekResolver(api: pageAPI, pages: pages, metadata: ScriptedSmartTransport([])).resolve(
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
        let capped = try await DeepSeekResolver(api: cappedAPI, pages: ScriptedSmartTransport([.init(html: manyLinks)]), metadata: ScriptedSmartTransport([]))
            .resolve("https://example.com/project 保存所有论文", apiKey: key, progress: { _ in })
        let cappedRequests = await cappedAPI.requests
        let cappedPayload = try JSONSerialization.jsonObject(with: cappedRequests[1].httpBody!) as! [String: Any]
        let cappedMessages = cappedPayload["messages"] as! [[String: Any]]
        let cappedObservation = try JSONSerialization.jsonObject(with: Data((cappedMessages.last!["content"] as! String).utf8)) as! [String: Any]
        try expect(capped.needsReview && capped.unresolved.isEmpty && capped.candidates.count <= SmartInput.candidateLimit &&
                   (cappedObservation["limitations"] as? [String])?.isEmpty == false,
                   "truncation remains tool evidence for the model to assess rather than manufacturing an unmet user requirement")

        let missingAPI = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(terminal([selection("r2")], unresolved: ["补充材料未找到"]))
        ])
        let missing = try await DeepSeekResolver(api: missingAPI, pages: ScriptedSmartTransport([.init(html: "<a href='/paper.pdf'>Paper</a>")]), metadata: ScriptedSmartTransport([]))
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
            let invalid = try call("propose_downloads", args)
            let transport = try ScriptedSmartTransport([.init(invalid), .init(invalid)])
            do {
                _ = try await DeepSeekResolver(api: transport, metadata: ScriptedSmartTransport([])).resolve("https://example.com/video.mp4 只要音频", apiKey: key, progress: { _ in })
                throw TestFailure.failed("invalid tool arguments must be rejected")
            } catch SmartResolverError.invalidResponse {}
        }
        let multi = try ScriptedSmartTransport([.init(call("propose_downloads", ["selections": [selection("r1")], "unresolved": []], additional: true))])
        do {
            _ = try await DeepSeekResolver(api: multi, metadata: ScriptedSmartTransport([])).resolve("https://example.com/video.mp4 只要音频", apiKey: key, progress: { _ in })
            throw TestFailure.failed("multiple simultaneous model tools must be rejected")
        } catch SmartResolverError.invalidResponse {}

        var limitedReplies: [ScriptedSmartTransport.Reply] = []
        for index in 0..<SmartInput.readCallLimit {
            limitedReplies.append(try .init(call("search_resources", ["query": "attempt \(index + 1)"])))
            limitedReplies.append(try .init(["results": [["title": "Unverified result", "url": "https://example.com/unverified.pdf", "summary": "Unknown identity"]]]))
        }
        limitedReplies.append(try .init(call("search_resources", ["query": "beyond read budget"])))
        let limit = ScriptedSmartTransport(limitedReplies)
        let limited = try await DeepSeekResolver(api: limit, metadata: ScriptedSmartTransport([])).resolve("找一篇论文", apiKey: key, progress: { _ in })
        let limitRequests = await limit.requests
        try expect(limited.modelCalls == SmartInput.modelCallLimit && limited.toolCalls == SmartInput.readCallLimit &&
                   limitRequests.count == SmartInput.modelCallLimit + SmartInput.readCallLimit &&
                   limited.needsReview && limited.selections.isEmpty && limited.candidates.isEmpty && !limited.unresolved.isEmpty,
                   "call limits stop before an extra read and never expose an unverified discovered file")

        let slow = try ScriptedSmartTransport([.init(terminal([selection("r1")]), delay: 500_000_000)])
        let timed = try await DeepSeekResolver(api: slow, metadata: ScriptedSmartTransport([]), budget: 0.01).resolve(
            "https://example.com/video.mp4 音频", apiKey: key, progress: { _ in })
        let timeoutCancelled = await slow.cancelled
        try expect(timed.needsReview && timed.selections.isEmpty && timeoutCancelled,
                   "deadline cancels the network and never accepts a late proposal")

        let cancellable = try ScriptedSmartTransport([.init(terminal([selection("r1")]), delay: 500_000_000)])
        let task = Task { try await DeepSeekResolver(api: cancellable, metadata: ScriptedSmartTransport([])).resolve("https://example.com/video.mp4 音频", apiKey: key, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()
        do { _ = try await task.value; throw TestFailure.failed("cancelled resolution must throw") }
        catch is CancellationError {}
        let wasCancelled = await cancellable.cancelled
        try expect(wasCancelled, "user cancellation propagates to the transport")

        let auth = try ScriptedSmartTransport([.init(["error": ["message": "SECRET response"]], status: 401)])
        do {
            _ = try await DeepSeekResolver(api: auth, metadata: ScriptedSmartTransport([])).resolve("找论文", apiKey: key, progress: { _ in })
            throw TestFailure.failed("unauthorized API must fail")
        } catch SmartResolverError.unauthorized {}
        let throttledSearch = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "paper"])), .init(["error": [:]], status: 429)
        ])
        do {
            _ = try await DeepSeekResolver(api: throttledSearch, metadata: ScriptedSmartTransport([])).resolve("找论文", apiKey: key, progress: { _ in })
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
                .init(response([tool("finish", "propose_downloads", proposal(notes: ["按对后续研究的影响选取代表作。"]))]))
            ])
            let result = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve(query, apiKey: key, thinking: .low, progress: { _ in })
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
            try expect(definitions.count == 3 && remainingTools.count == 3 &&
                       lastObservation["remaining_read_calls"] as? Int == SmartInput.readCallLimit - 2 && firstPrefix == replayedPrefix,
                       "two searches leave room for adaptive retrieval without rewriting the cached message prefix")
            let terminal = definitions.compactMap { $0["function"] as? [String: Any] }.first { $0["name"] as? String == "propose_downloads" }!
            let parameters = terminal["parameters"] as! [String: Any]
            try expect(!(parameters["required"] as! [String]).contains("notes") &&
                       (parameters["properties"] as? [String: Any])?["notes"] != nil,
                       "notes are an explicit optional protocol field, preserving existing terminal responses")
        }
        let genuine = try ScriptedSmartTransport([.init(response([tool("finish", "propose_downloads",
            proposal(unresolved: ["未找到请求的补充材料。"], notes: ["按研究影响选取代表作。"]))]))])
        let partial = try await DeepSeekResolver(api: genuine, metadata: ScriptedSmartTransport([])).resolve("https://example.com/paper.pdf 和补充材料",
            apiKey: key, progress: { _ in })
        try expect(partial.unresolved == ["未找到请求的补充材料。"] && partial.notes == ["按研究影响选取代表作。"] &&
                   partial.needsReview, "separate recommendation notes never erase a genuinely missing attachment")
        let invalidNotes: [Any] = [NSNull(), "not an array", [1], [""], Array(repeating: "note", count: 4), [String(repeating: "a", count: 201)]]
        for notes in invalidNotes {
            let invalid = try response([tool("finish", "propose_downloads", proposal(notes: notes))])
            let api = try ScriptedSmartTransport([.init(invalid), .init(invalid)])
            do {
                _ = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve("https://example.com/paper.pdf", apiKey: key, progress: { _ in })
                throw TestFailure.failed("malformed notes accepted")
            } catch SmartResolverError.invalidResponse {}
        }
        let search = try tool("s1", "search_resources", ["query": "first"])
        let second = try tool("s2", "search_resources", ["query": "second"])
        let finish = try tool("finish", "propose_downloads", proposal())
        let invalidBatches = [
            [search, search], [search, finish], [finish, finish],
            [search, second, try tool("s3", "search_resources", ["query": "third"])],
            [search, try tool("bad", "inspect_page", ["candidate_id": "unknown"])],
            [search, try tool("bad", "search_resources", ["query": "second", "extra": true])]
        ]
        for calls in invalidBatches {
            let api = try ScriptedSmartTransport([.init(response(calls))])
            do {
                _ = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve("找论文", apiKey: key, progress: { _ in })
                throw TestFailure.failed("invalid tool batch accepted")
            } catch SmartResolverError.invalidResponse {}
            let requests = await api.requests
            try expect(requests.count == 1, "invalid or mixed batches are rejected before any read request")
        }
        var overBudgetReplies: [ScriptedSmartTransport.Reply] = []
        for _ in 0..<(SmartInput.readCallLimit - 1) {
            overBudgetReplies.append(try .init(response([search])))
            overBudgetReplies.append(try .init(["results": []]))
        }
        overBudgetReplies.append(try .init(response([search, second])))
        let overBudget = ScriptedSmartTransport(overBudgetReplies)
        let exhausted = try await DeepSeekResolver(api: overBudget, metadata: ScriptedSmartTransport([])).resolve("找论文", apiKey: key, progress: { _ in })
        let exhaustedRequests = await overBudget.requests
        try expect(exhaustedRequests.count == 2 * (SmartInput.readCallLimit - 1) + 1 &&
                   exhausted.toolCalls == SmartInput.readCallLimit - 1 && exhausted.selections.isEmpty &&
                   !exhausted.unresolved.isEmpty, "a batch exceeding the remaining read budget is not partially executed")

        try await smartOfficialEvidenceTests()
        try await smartAdaptiveRetrievalTests()
        print("PASS subjective notes, real missing requirements, bounded read batches and verified arXiv titles")
    }

    // These fixtures exercise evidence supplied to the model, not its private
    // reasoning or the wording of the system prompt.
    private static func smartOfficialEvidenceTests() async throws {
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": [
                ["id": "evidence-call", "type": "function", "function": ["name": name,
                    "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]
            ]]]]]
        }
        func proposal(_ ids: [String], title: String = "") throws -> [String: Any] {
            try call("propose_downloads", ["selections": ids.map {
                ["candidate_id": $0, "title": title, "format": "inherit", "skip_existing": false] as [String: Any]
            }, "unresolved": []])
        }
        func messages(_ request: URLRequest) throws -> [[String: Any]] {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            return body["messages"] as! [[String: Any]]
        }
        func observations(_ request: URLRequest, role: String = "tool") throws -> [[[String: Any]]] {
            try messages(request).filter { $0["role"] as? String == role }.compactMap {
                guard let content = $0["content"] as? String,
                      let value = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
                else { return nil }
                return value["resources"] as? [[String: Any]]
            }
        }
        func official(_ row: [String: Any], id: String, title: String, authors: [String]) throws {
            let value = row["official_metadata"] as? [String: Any]
            try expect(row["metadata_status"] as? String == "available" &&
                       value?["arxiv_id"] as? String == id && value?["title"] as? String == title &&
                       value?["authors"] as? [String] == authors && value?["year"] as? Int == 2015 &&
                       value?["month"] as? Int == 12 && value?["source"] as? String == "https://arxiv.org/abs/" + id,
                       "model evidence contains the ID-matched official title, authors, date and versioned source")
        }
        func feed(_ entries: [String]) -> String {
            "<feed xmlns='http://www.w3.org/2005/Atom'>" + entries.map { xml in
                let start = xml.range(of: "<entry>")!.lowerBound
                let end = xml.range(of: "</entry>")!.upperBound
                return String(xml[start..<end])
            }.joined() + "</feed>"
        }
        func requestedIDs(_ request: URLRequest) -> Set<String> {
            let value = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id_list" })?.value ?? ""
            return Set(value.split(separator: ",").map(String.init))
        }
        let key = "synthetic-test-key"
        let residualTitle = "Deep Residual Learning for Image Recognition"
        let transformerTitle = "Attention Is All You Need"
        let residualAuthors = ["Kaiming He", "Xiangyu Zhang", "Shaoqing Ren", "Jian Sun"]
        let transformerAuthors = ["Ashish Vaswani", "Noam Shazeer"]
        let residual = smartArxivAtom()
        let transformer = smartArxivAtom(id: "1706.03762v7", title: transformerTitle, authors: transformerAuthors)

        let directMetadata = ScriptedSmartTransport([.init(html: feed([residual, transformer]), type: "application/atom+xml")])
        let direct = try ScriptedSmartTransport([.init(proposal(["r1"], title: "An invented model title"))])
        let directResult = try await DeepSeekResolver(api: direct, metadata: directMetadata).resolve(
            "只下载第一篇 https://arxiv.org/abs/1512.03385v1 https://arxiv.org/abs/1706.03762v7", apiKey: key, progress: { _ in })
        let directRequests = await direct.requests
        let initial = try observations(directRequests[0], role: "user")[0]
        try official(initial[0], id: "1512.03385v1", title: residualTitle, authors: residualAuthors)
        try official(initial[1], id: "1706.03762v7", title: transformerTitle, authors: transformerAuthors)
        let metadataRequests = await directMetadata.requests
        try expect(directResult.candidates[0].title == residualTitle &&
                   directResult.candidates[0].observedTitle == residualTitle && directResult.modelCalls == 1 &&
                   directResult.toolCalls == 0 && metadataRequests.count == 1 &&
                   requestedIDs(metadataRequests[0]) == ["1512.03385v1", "1706.03762v7"],
                   "all supplied paper evidence precedes the first model decision and no terminal lookup names an unseen paper")
        try expect(metadataRequests[0].url?.scheme == "https" && metadataRequests[0].url?.host == "export.arxiv.org" &&
                   metadataRequests[0].value(forHTTPHeaderField: "Authorization") == nil &&
                   metadataRequests[0].httpBody == nil && metadataRequests[0].timeoutInterval <= 2,
                   "official metadata is fetched in a bounded public batch without the DeepSeek credential")

        // The first search incorrectly labels ResNet as Transformer. The agent
        // sees both claims, refines the query, and proposes only the actual paper.
        let conflict = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "original Transformer paper"])),
            .init(["results": [["title": transformerTitle, "url": "https://arxiv.org/abs/1512.03385v1",
                                "summary": "A misleading search summary calling this the original Transformer."]]]),
            .init(call("search_resources", ["query": "Attention Is All You Need Vaswani 1706.03762"])),
            .init(["results": [["title": "1706.03762v7", "url": "https://arxiv.org/pdf/1706.03762v7",
                                "summary": "The original Transformer architecture by Vaswani and colleagues."]]]),
            .init(proposal(["r2"], title: transformerTitle))
        ])
        let conflictMetadata = ScriptedSmartTransport([.init(html: residual), .init(html: transformer)])
        let corrected = try await DeepSeekResolver(api: conflict, metadata: conflictMetadata).resolve(
            "下载提出 Transformer 的原始论文，排除综述", apiKey: key, progress: { _ in })
        let conflictRequests = await conflict.requests
        let firstEvidence = try observations(conflictRequests[2])[0][0]
        try official(firstEvidence, id: "1512.03385v1", title: residualTitle, authors: residualAuthors)
        try expect(firstEvidence["title"] as? String == transformerTitle &&
                   (firstEvidence["detail"] as? String)?.contains("misleading") == true,
                   "official evidence is separate from the conflicting search title and snippet")
        let finalEvidence = try observations(conflictRequests[4])
        let conflictMetadataRequests = await conflictMetadata.requests
        try official(finalEvidence[1][0], id: "1706.03762v7", title: transformerTitle, authors: transformerAuthors)
        try expect(finalEvidence.count == 2 && corrected.modelCalls == 3 && corrected.toolCalls == 2 &&
                   corrected.candidates.count == 1 && corrected.candidates[0].id == "r2" &&
                   corrected.candidates[0].title == transformerTitle && corrected.candidates[0].observedTitle == transformerTitle &&
                   (try? ArxivReference.parse(corrected.candidates[0].url.absoluteString))?.identifier == "1706.03762v7" &&
                   conflictMetadataRequests.count == 2,
                   "the scripted agent rejects the wrong identity, searches again and selects the evidence-backed original without a terminal fetch")

        let pageAPI = try ScriptedSmartTransport([
            .init(call("inspect_page", ["candidate_id": "r1"])), .init(proposal(["r2"]))
        ])
        let pageMetadata = ScriptedSmartTransport([.init(html: transformer)])
        let pageResult = try await DeepSeekResolver(api: pageAPI,
            pages: ScriptedSmartTransport([.init(html: "<a href='https://arxiv.org/html/1706.03762v7'>Transformer manuscript</a>")]),
            metadata: pageMetadata).resolve("读取 https://example.com/project 找到原始论文", apiKey: key, progress: { _ in })
        let pageRequests = await pageAPI.requests
        let pageEvidence = try observations(pageRequests[1])[0].first { $0["id"] as? String == "r2" }!
        let pageMetadataRequests = await pageMetadata.requests
        try official(pageEvidence, id: "1706.03762v7", title: transformerTitle, authors: transformerAuthors)
        try expect(pageResult.candidates.first(where: { $0.id == "r2" })?.title == transformerTitle &&
                   pageMetadataRequests.count == 1, "inspect-page paper links are enriched before the model selects them")

        let versionFeed = feed([
            smartArxivAtom(id: "1512.03385v2", title: "Second revision"),
            smartArxivAtom(id: "1512.03385v1", title: "First revision")
        ])
        for versions in [["1512.03385v1", "1512.03385v2"], ["1512.03385", "1512.03385v1"]] {
            let api = try ScriptedSmartTransport([.init(proposal(["r1", "r2"]))])
            let metadata = ScriptedSmartTransport([.init(html: versionFeed), .init(html: versionFeed)])
            let result = try await DeepSeekResolver(api: api, metadata: metadata).resolve(
                versions.map { "https://arxiv.org/abs/" + $0 }.joined(separator: " ") + " 下载这些版本", apiKey: key, progress: { _ in })
            let requests = await metadata.requests
            let apiRequests = await api.requests
            let rows = try observations(apiRequests[0], role: "user")[0]
            let expectedIDs = versions.map { $0.contains("v") ? $0 : $0 + "v2" }
            try expect(rows.compactMap { ($0["official_metadata"] as? [String: Any])?["arxiv_id"] as? String } == expectedIDs &&
                       result.candidates.count == 2 && result.selections.count == 2,
                       "explicit revisions retain their own ID-matched metadata even when a different revision appears first in Atom")
            if versions.contains("1512.03385") {
                try expect(requests.count == 2 && Set(requests.map(requestedIDs)) == Set([Set(["1512.03385"]), Set(["1512.03385v1"])]),
                           "latest and explicit revisions use separate metadata queries so a pinned revision cannot masquerade as latest")
            } else {
                try expect(requests.count == 1 && requestedIDs(requests[0]) == Set(versions),
                           "explicit versions are retrieved together and associated by complete identifiers")
            }
        }
        let exact = try AtomParser.metadata(Data(versionFeed.utf8), requested: ArxivReference.parse("1512.03385v1"))
        try expect(exact.reference.identifier == "1512.03385v1" && exact.title == "First revision",
                   "Atom matching searches past another revision of the same base ID")

        let longTitle = String(repeating: "Rigorous Methods for Reliable Retrieval ", count: 7).trimmingCharacters(in: .whitespaces)
        let manyAuthors = [String(repeating: "A", count: 200)] + (2...23).map { "Author \($0)" }
        let largeMetadata = ScriptedSmartTransport([.init(html: smartArxivAtom(title: longTitle, authors: manyAuthors))])
        let longAPI = try ScriptedSmartTransport([.init(proposal(["r1"], title: longTitle))])
        let longResult = try await DeepSeekResolver(api: longAPI, metadata: largeMetadata).resolve(
            "下载 https://arxiv.org/abs/1512.03385v1", apiKey: key, progress: { _ in })
        let longRequests = await longAPI.requests
        let longRow = try observations(longRequests[0], role: "user")[0][0]
        let longOfficial = longRow["official_metadata"] as! [String: Any]
        let observedAuthors = longOfficial["authors"] as! [String]
        try expect(longTitle.count > 200 && longResult.candidates.first?.title == longTitle &&
                   longResult.selections.count == 1 && longResult.modelCalls == 1 &&
                   longOfficial["title"] as? String == longTitle,
                   "a long official title already shown to the model remains valid without truncation or correction")
        try expect(observedAuthors.count == 20 && observedAuthors[0].count == 160 &&
                   longOfficial["author_count"] as? Int == manyAuthors.count && longOfficial["authors_truncated"] as? Bool == true,
                   "large author lists have bounded context with explicit total count and truncation evidence")

        let failures: [ScriptedSmartTransport.Reply] = [
            .init(html: smartArxivAtom(id: "1706.03762v1")),
            .init(html: smartArxivAtom(id: "1512.03385v2")),
            .init(html: "<!DOCTYPE feed [<!ENTITY x SYSTEM 'file:///private/file'>]><feed>&x;</feed>"),
            .init(html: "<invalid"),
            try .init(["error": "private upstream diagnostics"], status: 503)
        ]
        for reply in failures {
            let api = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "observed paper"])),
                .init(["results": [["title": "Observed Paper", "url": "https://arxiv.org/abs/1512.03385v1", "summary": "Observed original evidence"]]]),
                .init(proposal(["r1"], title: "Observed Paper"))
            ])
            let metadata = ScriptedSmartTransport([reply])
            let value = try await DeepSeekResolver(api: api, metadata: metadata).resolve("找到论文", apiKey: key, progress: { _ in })
            let requests = await api.requests
            let failedMetadataRequests = await metadata.requests
            let row = try observations(requests[2])[0][0]
            try expect(row["metadata_status"] as? String == "unavailable" && row["official_metadata"] == nil &&
                       row["title"] as? String == "Observed Paper" && row["detail"] as? String == "Observed original evidence" &&
                       value.candidates.first?.observedTitle == "Observed Paper" && value.unresolved.isEmpty &&
                       failedMetadataRequests.count == 2 && failedMetadataRequests[1].url?.absoluteString == "https://arxiv.org/abs/1512.03385v1",
                       "failed, wrong-ID/version or unsafe metadata retains observed evidence without inventing official identity or retrying at the terminal step")
            let serialized = String(decoding: requests[2].httpBody!, as: UTF8.self)
            try expect(!serialized.contains("file:///private/file") && !serialized.contains("private upstream diagnostics") &&
                       !serialized.contains(key), "metadata errors do not expose raw XML, private diagnostics or credentials to the model")
        }

        func citationHTML(citationID: String = "1512.03385", sourceID: String = "1512.03385v1",
                          date: String = "2015/12/10", extra: String = "") -> String {
            """
            <html><head>
            <meta name="citation_title" content="Deep Residual Learning for Image Recognition">
            <meta name="citation_arxiv_id" content="\(citationID)">
            <meta name="citation_date" content="\(date)">
            \(residualAuthors.map { "<meta name='citation_author' content='\($0)'>" }.joined())
            <meta property="og:url" content="https://arxiv.org/abs/\(sourceID)">
            \(extra)
            </head><body>Official paper page</body></html>
            """
        }
        for (requested, html) in [
            ("1512.03385v1", citationHTML()),
            ("1512.03385", citationHTML(citationID: "1512.03385v1", date: "2015-12-10"))
        ] {
            let api = try ScriptedSmartTransport([.init(proposal(["r1"]))])
            let metadata = try ScriptedSmartTransport([.init(["error": "temporarily unavailable"], status: 503), .init(html: html)])
            let result = try await DeepSeekResolver(api: api, metadata: metadata).resolve(
                "下载 https://arxiv.org/abs/" + requested, apiKey: key, progress: { _ in })
            let requests = await api.requests
            let metadataRequests = await metadata.requests
            let row = try observations(requests[0], role: "user")[0][0]
            try official(row, id: "1512.03385v1", title: residualTitle, authors: residualAuthors)
            try expect(result.candidates.first?.title == residualTitle && result.candidates.first?.observedTitle == residualTitle &&
                       result.modelCalls == 1 && metadataRequests.count == 2 &&
                       metadataRequests[0].url?.host == "export.arxiv.org" && metadataRequests[0].timeoutInterval <= 2 &&
                       metadataRequests[1].url?.absoluteString == "https://arxiv.org/abs/" + requested &&
                       metadataRequests[1].timeoutInterval <= 4 && metadataRequests.allSatisfy {
                           $0.value(forHTTPHeaderField: "Authorization") == nil
                       }, "official HTML rescues unavailable Atom metadata before the first decision and adds no terminal fetch or credential exposure")
        }
        let unsafeHTML: [ScriptedSmartTransport.Reply] = [
            .init(html: citationHTML(citationID: "1706.03762", sourceID: "1706.03762v7")),
            .init(html: citationHTML(citationID: "1512.03385v2", sourceID: "1512.03385v2")),
            .init(html: citationHTML(citationID: "1512.03385v2")),
            .init(html: "<html><head><script>" + citationHTML() + "</script></head><body></body></html>"),
            .init(html: "<html><head></head><body>" + citationHTML() + "</body></html>"),
            .init(html: "<html><body>" + citationHTML() + "</body></html>"),
            .init(html: citationHTML(extra: "<meta name='citation_title' content='Injected conflicting title'>")),
            .init(html: citationHTML(), responseURL: URL(string: "https://arxiv.org/abs/1706.03762v7")!),
            .init(html: citationHTML(), responseURL: URL(string: "https://attacker.example/abs/1512.03385v1")!)
        ]
        for html in unsafeHTML {
            let api = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "observed paper"])),
                .init(["results": [["title": "Observed Paper", "url": "https://arxiv.org/abs/1512.03385v1", "summary": "Original search evidence"]]]),
                .init(proposal(["r1"], title: "Observed Paper"))
            ])
            let metadata = try ScriptedSmartTransport([.init(["error": "unavailable"], status: 503), html])
            let result = try await DeepSeekResolver(api: api, metadata: metadata).resolve("找到论文", apiKey: key, progress: { _ in })
            let requests = await api.requests
            let metadataRequests = await metadata.requests
            let row = try observations(requests.last!)[0][0]
            try expect(row["metadata_status"] as? String == "unavailable" && row["official_metadata"] == nil &&
                       row["title"] as? String == "Observed Paper" && row["detail"] as? String == "Original search evidence" &&
                       result.candidates.first?.observedTitle == "Observed Paper" && metadataRequests.count == 2,
                       "HTML with wrong identity/version, hidden or duplicate metadata, or a mismatched response URL cannot establish official evidence")
        }
        let cappedHTMLAPI = try ScriptedSmartTransport([.init(proposal(["r1", "r2", "r3"]))])
        let cappedHTMLMetadata = try ScriptedSmartTransport([
            .init(["error": "unavailable"], status: 503), .init(html: "<html></html>"), .init(html: "<html></html>")
        ])
        _ = try await DeepSeekResolver(api: cappedHTMLAPI, metadata: cappedHTMLMetadata).resolve(
            "下载 https://arxiv.org/abs/1512.03385v1 https://arxiv.org/abs/1706.03762v7 https://arxiv.org/abs/1810.04805v1",
            apiKey: key, progress: { _ in })
        let cappedHTMLRequests = await cappedHTMLMetadata.requests
        try expect(cappedHTMLRequests.count == 3 && cappedHTMLRequests.filter { $0.url?.host == "arxiv.org" }.count == 2,
                   "one enrichment batch visits at most two missing official HTML pages, even when more metadata is unavailable")

        let delayedHTML = try ScriptedSmartTransport([
            .init(["error": "unavailable"], status: 503), .init(html: citationHTML(), delay: 200_000_000)
        ])
        let delayedHTMLAPI = try ScriptedSmartTransport([.init(proposal(["r1"]))])
        let timedHTML = try await DeepSeekResolver(api: delayedHTMLAPI, metadata: delayedHTML, budget: 0.02).resolve(
            "下载 https://arxiv.org/abs/1512.03385v1", apiKey: key, progress: { _ in })
        let delayedHTMLRequests = await delayedHTML.requests
        let delayedHTMLCancelled = await delayedHTML.cancelled
        let expiredHTMLModelRequests = await delayedHTMLAPI.requests
        try expect(delayedHTMLRequests.count == 2 && delayedHTMLRequests[1].timeoutInterval <= 0.02 && delayedHTMLCancelled &&
                   timedHTML.modelCalls == 0 && timedHTML.selections.isEmpty && expiredHTMLModelRequests.isEmpty,
                   "HTML fallback shares the original total deadline and cannot turn a late result into an accepted proposal")
        let cancellableHTML = try ScriptedSmartTransport([
            .init(["error": "unavailable"], status: 503), .init(html: citationHTML(), delay: 200_000_000)
        ])
        let cancelledHTMLAPI = try ScriptedSmartTransport([.init(proposal(["r1"]))])
        let htmlJob = Task {
            try await DeepSeekResolver(api: cancelledHTMLAPI, metadata: cancellableHTML).resolve(
                "下载 https://arxiv.org/abs/1512.03385v1", apiKey: key, progress: { _ in })
        }
        for _ in 0..<100 {
            if await cancellableHTML.requests.count == 2 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        htmlJob.cancel()
        do { _ = try await htmlJob.value; throw TestFailure.failed("cancelled HTML fallback returned a proposal") }
        catch is CancellationError {}
        let htmlWasCancelled = await cancellableHTML.cancelled
        let cancelledHTMLModelRequests = await cancelledHTMLAPI.requests
        try expect(htmlWasCancelled && cancelledHTMLModelRequests.isEmpty,
                   "user cancellation interrupts the HTML fallback before the model is called")

        let delayed = ScriptedSmartTransport([.init(html: residual, delay: 200_000_000)])
        let deadlineAPI = try ScriptedSmartTransport([.init(proposal(["r1"]))])
        let timed = try await DeepSeekResolver(api: deadlineAPI, metadata: delayed, budget: 0.02).resolve(
            "下载 https://arxiv.org/abs/1512.03385v1", apiKey: key, thinking: .max, progress: { _ in })
        let timedCancelled = await delayed.cancelled
        let delayedRequests = await delayed.requests
        let expiredAPIRequests = await deadlineAPI.requests
        try expect(timedCancelled && delayedRequests[0].timeoutInterval <= 0.02 && timed.modelCalls == 0 &&
                   timed.selections.isEmpty && timed.needsReview && expiredAPIRequests.isEmpty,
                   "initial evidence collection shares the total deadline and cannot start a model request after expiration")
        let cancellable = ScriptedSmartTransport([.init(html: residual, delay: 200_000_000)])
        let cancelAPI = try ScriptedSmartTransport([.init(proposal(["r1"]))])
        let job = Task {
            try await DeepSeekResolver(api: cancelAPI, metadata: cancellable).resolve(
                "下载 https://arxiv.org/abs/1512.03385v1", apiKey: key, progress: { _ in })
        }
        for _ in 0..<100 {
            if !(await cancellable.requests).isEmpty { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        job.cancel()
        do { _ = try await job.value; throw TestFailure.failed("cancelled evidence lookup returned a proposal") }
        catch is CancellationError {}
        let wasCancelled = await cancellable.cancelled
        let cancelledAPIRequests = await cancelAPI.requests
        try expect(wasCancelled && cancelledAPIRequests.isEmpty,
                   "cancellation stops metadata and prevents the initial model request")
        print("PASS official evidence before decisions, conflicting identities, version matching, failures and cancellation")
    }

    private static func smartAdaptiveRetrievalTests() async throws {
        func call(_ name: String, _ args: [String: Any]) throws -> [String: Any] {
            ["choices": [["finish_reason": "tool_calls", "message": ["role": "assistant", "tool_calls": [
                ["id": "adaptive-call", "type": "function", "function": ["name": name,
                    "arguments": String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)]]
            ]]]]]
        }
        func proposal(_ ids: [String], title: String = "") throws -> [String: Any] {
            try call("propose_downloads", ["selections": ids.map {
                ["candidate_id": $0, "title": title, "format": "inherit", "skip_existing": false] as [String: Any]
            }, "unresolved": []])
        }
        func payload(_ request: URLRequest) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        func observations(_ request: URLRequest) throws -> [[String: Any]] {
            let messages = try payload(request)["messages"] as! [[String: Any]]
            return try messages.filter { $0["role"] as? String == "tool" }.map {
                try JSONSerialization.jsonObject(with: Data(($0["content"] as! String).utf8)) as! [String: Any]
            }
        }
        let key = "synthetic-test-key"
        let api = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "ResNet original paper and supplement"])),
            .init(["results": [["title": "Research archive", "url": "https://example.com/project"]]]),
            .init(call("inspect_page", ["candidate_id": "r1"])),
            .init(call("search_resources", ["query": "Deep Residual Learning for Image Recognition supplementary materials"])),
            .init(["results": [
                ["title": "Residual learning", "url": "https://arxiv.org/abs/1512.03385v1"],
                ["title": "Supplement archive", "url": "https://example.com/supplements"]
            ]]),
            .init(call("inspect_page", ["candidate_id": "r4"])),
            .init(proposal(["r3", "r5"]))
        ])
        let pages = ScriptedSmartTransport([
            .init(html: "<h1>Archived editions</h1><a href='/edition'>Archive</a>"),
            .init(html: "<a href='/supp.zip'>Supplementary materials</a>")
        ])
        let metadata = ScriptedSmartTransport([.init(html: smartArxivAtom())])
        let result = try await DeepSeekResolver(api: api, pages: pages, metadata: metadata).resolve(
            "下载 ResNet 原始论文和补充材料", apiKey: key, progress: { _ in })
        let requests = await api.requests
        let final = try payload(requests.last!)
        let history = try observations(requests.last!)
        let finalTools = final["tools"] as! [[String: Any]]
        let official = (history[2]["resources"] as! [[String: Any]])[0]["official_metadata"] as? [String: Any]
        try expect(result.modelCalls == 5 && result.toolCalls == 4 &&
                   history.count == 4 && history.last?["remaining_read_calls"] as? Int == SmartInput.readCallLimit - 4 &&
                   finalTools.count == 3 &&
                   result.selections.map(\.candidateID) == ["r3", "r5"] && result.unresolved.isEmpty &&
                   official?["title"] as? String == "Deep Residual Learning for Image Recognition",
                   "the agent can search, read, refine, read again and propose both requested files inside the complete budget")
        let archive = (history[1]["resources"] as! [[String: Any]]).first { $0["id"] as? String == "r2" }
        try expect(archive?["url"] as? String == "https://example.com/edition",
                   "inspect exposes safe ordinary links so the agent can assess them without host keyword guesses")
        let pageRequests = await pages.requests
        let metadataRequests = await metadata.requests
        try expect(pageRequests.count == 2 && metadataRequests.count == 1 &&
                   pageRequests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil },
                   "adaptive retrieval uses the requested tools only and never forwards API credentials to source pages")

        for selectedTitle in ["Earlier title", "Updated title"] {
            let repeated = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "first wording"])),
                .init(["results": [["title": "Earlier title", "url": "https://example.com/same.pdf", "summary": "First observation"]]]),
                .init(call("search_resources", ["query": "more specific wording"])),
                .init(["results": [
                    ["title": "Updated title", "url": "https://example.com/same.pdf", "summary": "New observation"],
                    ["title": "Updated title", "url": "https://example.com/different.pdf", "summary": "Another resource with the same title"]
                ]]),
                .init(proposal(["r1"], title: selectedTitle))
            ])
            let emptyMetadata = ScriptedSmartTransport([])
            let repeatedResult = try await DeepSeekResolver(api: repeated, metadata: emptyMetadata).resolve(
                "找到目标文件", apiKey: key, progress: { _ in })
            let repeatedRequests = await repeated.requests
            let history = try observations(repeatedRequests.last!)
            let oldRows = history[0]["resources"] as! [[String: Any]]
            let newRows = history[1]["resources"] as! [[String: Any]]
            let emptyRequests = await emptyMetadata.requests
            try expect(oldRows[0]["id"] as? String == "r1" && oldRows[0]["title"] as? String == "Earlier title" &&
                       oldRows[0]["detail"] as? String == "First observation" && newRows[0]["id"] as? String == "r1" &&
                       newRows[0]["title"] as? String == "Updated title" && newRows[0]["detail"] as? String == "New observation" &&
                       newRows[1]["id"] as? String == "r2" && repeatedResult.candidates[0].observedTitle == selectedTitle &&
                       emptyRequests.isEmpty,
                       "repeat URLs return fresh evidence while preserving prior claims; unrelated URLs never merge by title or trigger paper metadata")
        }

        let aliases = ["https://arxiv.org/abs/1512.03385v1", "https://arxiv.org/pdf/1512.03385v1.pdf",
                       "https://arxiv.org/html/1512.03385v1", "https://arxiv.org/abs/1512.03385v2", "https://arxiv.org/abs/1512.03385"]
        let aliasAPI = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "paper versions"])),
            .init(["results": aliases.enumerated().map { ["title": "Observed source \($0.offset + 1)", "url": $0.element] }]),
            .init(proposal(["r1", "r2", "r3"]))
        ])
        let aliasResult = try await DeepSeekResolver(api: aliasAPI, metadata: ScriptedSmartTransport([])).resolve(
            "下载这些版本", apiKey: key, progress: { _ in })
        let aliasRequests = await aliasAPI.requests
        let aliasRows = try observations(aliasRequests.last!)[0]["resources"] as! [[String: Any]]
        try expect(aliasRows.count == 3 && Set(aliasRows.compactMap { $0["id"] as? String }).count == 3 &&
                   (aliasRows[0]["additional_evidence"] as? [[String: Any]])?.count == 2 &&
                   aliasResult.candidates.compactMap { try? ArxivReference.parse($0.url.absoluteString).identifier } ==
                       ["1512.03385v1", "1512.03385v2", "1512.03385"],
                   "abs/pdf/html aliases share one candidate while explicit revisions and an unpinned latest remain distinct")

        // Each allowed page read can expose 20 links alongside the supplied pages.
        // The last legitimate ID must remain selectable instead of being lost
        // to the previous 30-candidate ceiling.
        let supplied = (1...SmartInput.targetLimit).map { "https://example.com/page\($0)" }.joined(separator: " ")
        var capacityReplies: [ScriptedSmartTransport.Reply] = []
        var capacityPages: [ScriptedSmartTransport.Reply] = []
        for index in 1...SmartInput.readCallLimit {
            capacityReplies.append(try .init(call("inspect_page", ["candidate_id": "r\(index)"])))
            capacityPages.append(.init(html: (1...20).map { "<a href='/batch\(index)/paper\($0).pdf'>Paper \(index)-\($0)</a>" }.joined()))
        }
        capacityReplies.append(try .init(proposal(["r\(SmartInput.candidateLimit)"])))
        let capacityAPI = ScriptedSmartTransport(capacityReplies)
        let capacity = try await DeepSeekResolver(api: capacityAPI, pages: ScriptedSmartTransport(capacityPages),
            metadata: ScriptedSmartTransport([])).resolve(supplied + " 找到最后一份附件", apiKey: key, progress: { _ in })
        let capacityRequests = await capacityAPI.requests
        let allObserved = try observations(capacityRequests.last!).flatMap { $0["resources"] as! [[String: Any]] }
        try expect(allObserved.count == SmartInput.readCallLimit * 20 && capacity.selections.map(\.candidateID) == ["r\(SmartInput.candidateLimit)"] &&
                   allObserved.last?["id"] as? String == "r\(SmartInput.candidateLimit)" &&
                   capacity.candidates.last?.url.path == "/batch\(SmartInput.readCallLimit)/paper20.pdf",
                   "the bounded registry can retain every link permitted by the configured read budget")
        print("PASS adaptive retrieval, stable IDs with fresh evidence, version-aware deduplication and candidate capacity")
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
        let good = try call("good", "propose_downloads",
            proposal([selection("r2", format: "audio", skip: true)], unresolved: ["未找到所要求的字幕。"]))
        let invalidRows: [[[String: Any]]] = [
            [selection("r99")],
            [["candidate_id": "r2", "format": "audio"]],
            [selection("r2", format: "pdf")],
            [selection("r2"), selection("r2")]
        ]
        for rows in invalidRows {
            let bad = try call("bad", "propose_downloads", proposal(rows))
            let api = try ScriptedSmartTransport([.init(bad), .init(good)])
            let result = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, progress: { _ in })
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
            try expect(tools.count == 1 && (tools[0]["function"] as? [String: Any])?["name"] as? String == "propose_downloads" &&
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
        let pageProposal = try call("bad-page", "propose_downloads", proposal([selection("r1")]), reasoning: correctionReasoning)
        let paperProposal = try call("paper", "propose_downloads", proposal([selection("r2")]), reasoning: "terminal reasoning")
        let api = try ScriptedSmartTransport([.init(search), .init(hits), .init(pageProposal), .init(paperProposal)])
        let repaired = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve("找到所要求的论文", apiKey: key, thinking: .low, progress: { _ in })
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

        let invalid = try call("bad", "propose_downloads", proposal([selection("r99")]))
        let repeated = try ScriptedSmartTransport([.init(invalid), .init(invalid), .init(good)])
        do {
            _ = try await DeepSeekResolver(api: repeated, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, progress: { _ in })
            throw TestFailure.failed("a second invalid proposal was accepted or repaired twice")
        } catch SmartResolverError.invalidResponse {}
        try expect(await repeated.requests.count == 2, "only one proposal correction is allowed even with a third turn available")

        let firstSearch = try call("first", "search_resources", ["query": "first"])
        let forbiddenRead = try ScriptedSmartTransport([.init(invalid), .init(firstSearch)])
        do {
            _ = try await DeepSeekResolver(api: forbiddenRead, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, progress: { _ in })
            throw TestFailure.failed("a correction invoked a read tool that was no longer available")
        } catch SmartResolverError.invalidResponse {}
        try expect(await forbiddenRead.requests.count == 2, "the host rejects a read during correction before any read request")
        var lastReplies: [ScriptedSmartTransport.Reply] = []
        for _ in 0..<SmartInput.readCallLimit {
            lastReplies.append(try .init(firstSearch))
            lastReplies.append(try .init(["results": []]))
        }
        lastReplies.append(try .init(invalid))
        lastReplies.append(try .init(good))
        let lastTurn = ScriptedSmartTransport(lastReplies)
        do {
            _ = try await DeepSeekResolver(api: lastTurn, metadata: ScriptedSmartTransport([])).resolve("找论文", apiKey: key, progress: { _ in })
            throw TestFailure.failed("last-turn invalid proposal received an extra model call")
        } catch SmartResolverError.invalidResponse {}
        try expect(await lastTurn.requests.count == SmartInput.modelCallLimit + SmartInput.readCallLimit,
                   "correction never exceeds the shared model/read budgets")
        let lastRequests = await lastTurn.requests
        let lastPayload = try JSONSerialization.jsonObject(with: lastRequests.last!.httpBody!) as! [String: Any]
        let lastTools = lastPayload["tools"] as! [[String: Any]]
        try expect(lastTools.count == 1 && (lastTools[0]["function"] as? [String: Any])?["name"] as? String == "propose_downloads",
                   "the last model turn advertises only a terminal proposal")

        let missingReasoning = try ScriptedSmartTransport([.init(invalid), .init(good)])
        do {
            _ = try await DeepSeekResolver(api: missingReasoning, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, thinking: .high, progress: { _ in })
            throw TestFailure.failed("thinking correction continued without required reasoning")
        } catch SmartResolverError.invalidResponse {}
        try expect(await missingReasoning.requests.count == 1, "an incomplete thinking tool message cannot be corrected through an invalid continuation")

        let slow = try ScriptedSmartTransport([.init(invalid), .init(good, delay: 300_000_000)])
        let timed = try await DeepSeekResolver(api: slow, metadata: ScriptedSmartTransport([]), budget: 0.02).resolve(input, apiKey: key, progress: { _ in })
        let timedCancelled = await slow.cancelled
        try expect(timed.selections.isEmpty && !timed.unresolved.isEmpty && timedCancelled,
                   "correction stays inside the original deadline and cannot accept a late proposal")
        let cancellable = try ScriptedSmartTransport([.init(invalid), .init(good, delay: 300_000_000)])
        let job = Task { try await DeepSeekResolver(api: cancellable, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, progress: { _ in }) }
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
            try call("propose_downloads", ["selections": [["candidate_id": id, "title": title,
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
            let result = try await DeepSeekResolver(api: api, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, thinking: effort, progress: { _ in })
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
                       "the request uses the selected overall deadline")
            try expect(result.selections.count == 1 &&
                       result.usage == SmartTokenUsage(inputTokens: 100, outputTokens: 20, totalTokens: 120, cacheHitTokens: 60),
                       "each mode returns the proposal and actual numeric usage")
        }
        let capped = try ScriptedSmartTransport([.init(terminal("r1"))])
        _ = try await DeepSeekResolver(api: capped, metadata: ScriptedSmartTransport([]), budget: 2).resolve(input, apiKey: key, thinking: .max, progress: { _ in })
        let cappedRequests = await capped.requests
        try expect(cappedRequests[0].timeoutInterval <= 2, "an injected deadline is never enlarged by the thinking setting")
        let prose = try ScriptedSmartTransport([.init(["choices": [["finish_reason": "stop",
            "message": ["role": "assistant", "content": "A plain-text answer is not a download proposal.",
                        "reasoning_content": "private reasoning"]]]])])
        do {
            _ = try await DeepSeekResolver(api: prose, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, thinking: .low, progress: { _ in })
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
        let result = try await DeepSeekResolver(api: api, pages: pages, metadata: ScriptedSmartTransport([])).resolve("找到 Bounded Paper", apiKey: key,
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
                _ = try await DeepSeekResolver(api: invalid, metadata: ScriptedSmartTransport([])).resolve("找到论文", apiKey: key, thinking: .low, progress: { _ in })
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
        let emptyResult = try await DeepSeekResolver(api: emptyReasoning, metadata: ScriptedSmartTransport([])).resolve("找到论文", apiKey: key,
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
            let value = try await DeepSeekResolver(api: malformed, metadata: ScriptedSmartTransport([])).resolve(input, apiKey: key, progress: { _ in })
            try expect(value.selections.count == 1 && value.usage == nil,
                       "malformed token counters do not become invented usage or invalidate an otherwise valid proposal")
        }
        let partial = try ScriptedSmartTransport([
            .init(call("search_resources", ["query": "paper"], usage: usage(100, 10, 50))),
            .init(["results": [["title": "Paper", "url": "https://example.com/paper.pdf"]]]),
            .init(terminal("r1", title: "Paper"))
        ])
        let partialResult = try await DeepSeekResolver(api: partial, metadata: ScriptedSmartTransport([])).resolve("找到论文", apiKey: key, progress: { _ in })
        try expect(partialResult.usage == nil, "partial usage is not presented as the complete request total")
        let slow = try ScriptedSmartTransport([.init(terminal("r1", usage: usage(100, 10, 50)), delay: 300_000_000)])
        let timed = try await DeepSeekResolver(api: slow, metadata: ScriptedSmartTransport([]), budget: 0.01).resolve(input, apiKey: key,
            thinking: .max, progress: { _ in })
        let cancelled = await slow.cancelled
        try expect(timed.needsReview && timed.selections.isEmpty && timed.usage == nil && cancelled,
                   "max thinking still cancels at the injected deadline and never reports incomplete usage or success")

        // Conflicting claims share an identity but must all be visible. The
        // host only checks literal evidence; the agent judges which is true.
        for proposed in ["Beta Paper", "Alpha Paper", "Only on A"] {
            let repeated = try ScriptedSmartTransport([
                .init(call("search_resources", ["query": "two papers"])),
                .init(["results": [
                    ["title": "Paper collection", "url": "https://example.com/collection",
                     "summary": "Alpha Paper: Only on A [PDF](https://example.com/a.pdf)\nBeta Paper [PDF](https://example.com/b.pdf)"],
                    ["title": "Alpha Paper", "url": "https://example.com/b.pdf", "summary": "Unrelated duplicate title"]
                ]]),
                .init(terminal("r3", title: proposed))
            ])
            let repeatedResult = try await DeepSeekResolver(api: repeated, metadata: ScriptedSmartTransport([])).resolve("找到 Beta Paper", apiKey: key, progress: { _ in })
            let repeatedRequests = await repeated.requests
            let messages = try payload(repeatedRequests[2])["messages"] as! [[String: Any]]
            let observation = try JSONSerialization.jsonObject(with: Data((messages.last!["content"] as! String).utf8)) as! [String: Any]
            let observed = observation["resources"] as! [[String: Any]]
            let conflicting = observed.first { $0["id"] as? String == "r3" }?["additional_evidence"] as? [[String: Any]]
            try expect(observed.count == 3 && Set(observed.compactMap { $0["id"] as? String }).count == 3 &&
                       conflicting?.first?["title"] as? String == "Alpha Paper" &&
                       conflicting?.first?["detail"] as? String == "Unrelated duplicate title" &&
                       repeatedResult.candidates.first?.url.absoluteString == "https://example.com/b.pdf" &&
                       repeatedResult.candidates.first?.observedTitle == (proposed == "Only on A" ? nil : proposed),
                       "duplicate IDs expose conflicting claims, retain prior evidence and cannot copy a title observed only for another candidate")
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
            ("bert-original", "下载 Devlin 等人在 2018 年提出 BERT 的原始论文，排除综述和后续改进。", .off),
            ("transformer-v1", "下载 Attention Is All You Need（Vaswani 等，2017）最初的 arXiv v1 版本，排除后续版本和综述。", .off),
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
            let known = Set(samples.map(\.0)).union(["download-pipeline", "evidence-conflict"])
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
                try expect(result.modelCalls <= SmartInput.modelCallLimit && result.toolCalls <= SmartInput.readCallLimit, "live call budgets are enforced")
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
                    let requiresPage = name == "page" || effort != .off
                    try expect(result.needsReview && result.candidates.contains(where: {
                        requiresPage ? $0.origin == .page : $0.origin == .search || $0.origin == .page
                    }),
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
                    } else if ["search", "bert-original", "transformer-v1"].contains(name) {
                        let ids = Set(result.selections.map(\.candidateID))
                        let selected = result.candidates.filter { ids.contains($0.id) }
                        let title = name == "bert-original" ? "BERT: Pre-training of Deep Bidirectional Transformers for Language Understanding"
                            : "Attention Is All You Need"
                        let baseID = name == "bert-original" ? "1810.04805" : "1706.03762"
                        try expect(!selected.isEmpty && result.unresolved.isEmpty && selected.allSatisfy {
                            guard let reference = try? ArxivReference.parse($0.url.absoluteString) else { return false }
                            return reference.baseID == baseID && (name != "transformer-v1" || reference.version == 1) &&
                                $0.title.caseInsensitiveCompare(title) == .orderedSame && $0.observedTitle == $0.title
                        }, "live retrieval must identify the requested original paper and explicit revision, not any plausible candidate")
                    }
                }
            } catch { record(name, error) }
            for event in await trace.events { print("LIVE protocol \(name): \(publicText(event, limit: 2000))") }
        }
        if selectedNames == nil || selectedNames!.contains("evidence-conflict") {
            let trace = SmartLiveTraceTransport()
            let transport = SmartLiveConflictTransport(model: trace)
            let metadata = ScriptedSmartTransport([
                .init(html: smartArxivAtom()),
                .init(html: smartArxivAtom(id: "1706.03762v7", title: "Attention Is All You Need", authors: ["Ashish Vaswani", "Noam Shazeer"],
                    published: "2017-06-12T00:00:00Z"))
            ])
            do {
                let result = try await DeepSeekResolver(api: transport, metadata: metadata).resolve(
                    "下载提出 Transformer 的原始论文 Attention Is All You Need（Vaswani 等，2017），不要综述或引用它的其他论文。",
                    apiKey: key, progress: { _ in })
                let searches = await transport.searchCalls
                let ids = Set(result.selections.map(\.candidateID))
                let selected = result.candidates.filter { ids.contains($0.id) }
                try expect(searches >= 2 && searches <= SmartInput.readCallLimit &&
                           result.modelCalls <= SmartInput.modelCallLimit && !selected.isEmpty && result.unresolved.isEmpty &&
                           selected.allSatisfy {
                               (try? ArxivReference.parse($0.url.absoluteString))?.identifier == "1706.03762v7" &&
                                   $0.title == "Attention Is All You Need" && $0.observedTitle == $0.title
                           }, "real agent must reject the misleading ResNet hit using official evidence, then retrieve and select Transformer")
                print("PASS live evidence-conflict: actual model rejected wrong paper identity and refined search; model=\(result.modelCalls), searches=\(searches)")
            } catch { record("evidence-conflict", error) }
            for event in await trace.events { print("LIVE protocol evidence-conflict: \(publicText(event, limit: 2000))") }
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

import Foundation

actor ProbeTransport: HTTPTransport {
    let pdf: URL
    let status: Int
    init(pdf: URL, status: Int) { self.pdf = pdf; self.status = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        print("request \(Date().timeIntervalSince1970)"); fflush(stdout)
        let data = Data("<feed><entry><id>https://arxiv.org/abs/2501.12345v2</id><title>IPC fixture</title><published>2025-01-01</published></entry></feed>".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: status == 429 ? ["Retry-After": "600"] : nil)!)
    }
    func download(for request: URLRequest, progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> (URL, HTTPURLResponse) {
        print("request \(Date().timeIntervalSince1970)"); fflush(stdout)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-\(UUID().uuidString).pdf")
        try FileManager.default.copyItem(at: pdf, to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@main struct CoordinationProbe {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args[0] == "preferences" {
                let value = DownloadPreferences(UserDefaults(suiteName: args[1])!)
                print(value.directory.path); print(value.naming.rawValue); return
            }
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            let coordinator = RequestCoordinator(directory: directory)
            if args[0] == "lock" {
                let lease = try await coordinator.acquire()
                print("acquired"); fflush(stdout)
                try await Task.sleep(nanoseconds: 30_000_000_000)
                withExtendedLifetime(lease) { }
            } else {
                do { let initial = try await coordinator.acquire(); withExtendedLifetime(initial) { } }
                let folder = directory.appendingPathComponent("papers", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let engine = DownloadEngine(transport: ProbeTransport(pdf: URL(fileURLWithPath: args[2]), status: args[0] == "429" ? 429 : 200), requestInterval: 0.2, retryDelay: 0, coordinator: coordinator)
                _ = try await engine.download(ArxivReference.parse("2501.12345v2"), to: folder)
            }
        } catch DownloadError.cooldown { print("cooldown"); fflush(stdout) }
        catch { fputs("\(error)\n", stderr); exit(1) }
    }
}

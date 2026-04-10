//
//  readers.swift
//  Claude
//
//  Created by Stats Claude Module
//

import Cocoa
import Kit

internal class ClaudeUsageReader: Reader<Claude_Usage> {
    private var lastKnownUsage: Claude_Usage? = nil
    private var proxyProcess: Process? = nil
    private var proxyPort: Int? = nil

    private static let rateLimitFile = "/tmp/claude-rate-limits.json"
    private static let proxyScript = "/tmp/claude-rate-proxy.py"

    override init(_ module: ModuleType, popup: Bool = false, preview: Bool = false, history: Bool = false, callback: @escaping (Claude_Usage?) -> Void = {_ in }) {
        super.init(module, popup: popup, preview: preview, history: history, callback: callback)
        self.defaultInterval = 60
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.read()
        }
    }

    public override func read() {
        // 1. Ensure proxy is running
        if proxyPort == nil {
            startProxy()
        }
        guard let port = proxyPort else {
            self.callback(self.lastKnownUsage)
            return
        }

        // 2. Run claude through proxy (spawns a short-lived process)
        runClaudeThroughProxy(port: port)

        // 3. Read captured rate limit headers
        guard let data = FileManager.default.contents(atPath: Self.rateLimitFile),
              let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            self.callback(self.lastKnownUsage)
            return
        }

        var usage = Claude_Usage()
        usage.utilization5h = Double(headers["anthropic-ratelimit-unified-5h-utilization"] ?? "0") ?? 0
        usage.utilization7d = Double(headers["anthropic-ratelimit-unified-7d-utilization"] ?? "0") ?? 0
        usage.overageUtilization = Double(headers["anthropic-ratelimit-unified-overage-utilization"] ?? "0") ?? 0
        usage.fallbackPercentage = Double(headers["anthropic-ratelimit-unified-fallback-percentage"] ?? "0") ?? 0
        usage.status5h = headers["anthropic-ratelimit-unified-5h-status"] ?? "unknown"
        usage.status7d = headers["anthropic-ratelimit-unified-7d-status"] ?? "unknown"

        if let resetStr = headers["anthropic-ratelimit-unified-5h-reset"], let ts = Double(resetStr) {
            usage.reset5h = Date(timeIntervalSince1970: ts)
        }
        if let resetStr = headers["anthropic-ratelimit-unified-7d-reset"], let ts = Double(resetStr) {
            usage.reset7d = Date(timeIntervalSince1970: ts)
        }

        self.lastKnownUsage = usage
        self.callback(usage)
    }

    override func terminate() {
        proxyProcess?.terminate()
        proxyProcess = nil
        proxyPort = nil
    }

    // MARK: - Proxy

    private func startProxy() {
        // Write proxy script
        let script = """
        import http.server, http.client, json, ssl, sys

        RESULT_FILE = "\(Self.rateLimitFile)"

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
                ctx = ssl.create_default_context()
                c = http.client.HTTPSConnection("api.anthropic.com", context=ctx)
                fh = {k: v for k, v in self.headers.items() if k.lower() != "host"}
                c.request("POST", self.path, body, fh)
                r = c.getresponse()
                rb = r.read()
                rl = {k.lower(): v for k, v in r.getheaders() if "ratelimit" in k.lower()}
                if rl:
                    json.dump(rl, open(RESULT_FILE, "w"))
                self.send_response(r.status)
                for k, v in r.getheaders():
                    if k.lower() not in ("transfer-encoding",):
                        self.send_header(k, v)
                self.end_headers()
                self.wfile.write(rb)
            def log_message(self, *a): pass

        s = http.server.HTTPServer(("127.0.0.1", 0), H)
        print(s.server_address[1], flush=True)
        s.serve_forever()
        """
        try? script.write(toFile: Self.proxyScript, atomically: true, encoding: .utf8)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [Self.proxyScript]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return }

        // Read port from first line of stdout
        let portData = pipe.fileHandleForReading.availableData
        if let portStr = String(data: portData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let port = Int(portStr) {
            self.proxyPort = port
            self.proxyProcess = proc
        } else {
            proc.terminate()
        }
    }

    private func runClaudeThroughProxy(port: Int) {
        guard let claudePath = Self.resolveClaude() else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["-p", ".", "--model", "claude-haiku-4-5-20251001", "--max-turns", "1", "--output-format", "json"]
        proc.environment = ProcessInfo.processInfo.environment.merging(
            ["ANTHROPIC_BASE_URL": "http://127.0.0.1:\(port)"],
            uniquingKeysWith: { _, new in new }
        )
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return }
        proc.waitUntilExit()
    }

    private static func resolveClaude() -> String? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude"
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}

import Darwin
import Foundation

public enum DNSLookup {
    public static func resolve(_ host: String, timeout: TimeInterval) async -> StageResult {
        let start = Date()
        let outcome: Int32? = await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                await withCheckedContinuation { cont in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
                        var result: UnsafeMutablePointer<addrinfo>?
                        let code = getaddrinfo(host, nil, &hints, &result)
                        if let result { freeaddrinfo(result) }
                        cont.resume(returning: code)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let elapsed = Date().timeIntervalSince(start)
        guard let code = outcome else { return StageResult(kind: .dns, state: .timedOut, duration: elapsed, detail: "No answer in \(Int(timeout)) seconds") }
        if code == 0 { return StageResult(kind: .dns, state: .passed, duration: elapsed) }
        let detail = code == EAI_NONAME ? "This name was not found" : (code == EAI_AGAIN ? "The name server did not answer" : String(cString: gai_strerror(code)))
        return StageResult(kind: .dns, state: .failed, duration: elapsed, detail: detail)
    }
}

private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    var metrics: URLSessionTaskTransactionMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        self.metrics = metrics.transactionMetrics.last
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

public enum EndpointTester {
    public static func run(_ endpoint: EndpointDefinition, pathAvailable: Bool) async -> EndpointTestResult {
        let started = Date()
        guard let url = EndpointDefinition.validate(endpoint.url), let host = url.host else {
            return EndpointTestResult(endpointID: endpoint.id, endpointName: endpoint.name, host: endpoint.url, startedAt: started,
                                      stages: [StageResult(kind: .dns, state: .unsupported, detail: "Not a valid web address")])
        }
        var stages = [StageResult(kind: .path, state: pathAvailable ? .passed : .failed, detail: pathAvailable ? nil : "No usable connection")]
        guard pathAvailable else {
            stages += [.dns, .connect, .tls, .http].map { StageResult(kind: $0, state: .skipped) }
            return EndpointTestResult(endpointID: endpoint.id, endpointName: endpoint.name, host: host, startedAt: started, stages: stages)
        }
        let isIP = host.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        if isIP {
            stages.append(StageResult(kind: .dns, state: .skipped, detail: "Address used directly"))
        } else {
            let dns = await DNSLookup.resolve(host, timeout: min(endpoint.timeout, 4))
            stages.append(dns)
            if dns.state != .passed {
                stages += [.connect, .tls, .http].map { StageResult(kind: $0, state: .skipped) }
                return EndpointTestResult(endpointID: endpoint.id, endpointName: endpoint.name, host: host, startedAt: started, stages: stages)
            }
        }
        if Task.isCancelled {
            stages += [.connect, .tls, .http].map { StageResult(kind: $0, state: .skipped, detail: "Cancelled") }
            return EndpointTestResult(endpointID: endpoint.id, endpointName: endpoint.name, host: host, startedAt: started, stages: stages)
        }
        let web = await fetch(url, endpoint: endpoint)
        stages += web.stages
        return EndpointTestResult(endpointID: endpoint.id, endpointName: endpoint.name, host: host, startedAt: started, stages: stages, httpStatus: web.status, bytes: web.bytes)
    }

    public static func connectTime(_ endpoint: EndpointDefinition) async -> TimeInterval? {
        guard let url = EndpointDefinition.validate(endpoint.url) else { return nil }
        let result = await fetch(url, endpoint: endpoint)
        guard result.stages.allSatisfy({ $0.state == .passed || $0.state == .skipped || $0.kind == .http }) else { return nil }
        return result.stages.first { $0.kind == .connect }?.duration
    }

    private static func fetch(_ url: URL, endpoint: EndpointDefinition) async -> (stages: [StageResult], status: Int?, bytes: Int?) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = endpoint.timeout
        config.timeoutIntervalForResource = endpoint.timeout + 1
        config.httpMaximumConnectionsPerHost = 1
        let delegate = MetricsDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Macin network check", forHTTPHeaderField: "User-Agent")

        var status: Int?
        var count = 0
        var failure: URLError?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            status = (response as? HTTPURLResponse)?.statusCode
            for try await _ in bytes {
                count += 1
                if count >= endpoint.maxBytes { break }
            }
        } catch let error as URLError {
            failure = error
        } catch {
            failure = URLError(.unknown)
        }
        try? await Task.sleep(for: .milliseconds(30))
        let m = delegate.metrics

        func span(_ a: Date?, _ b: Date?) -> TimeInterval? {
            guard let a, let b else { return nil }
            return max(0, b.timeIntervalSince(a))
        }
        let isHTTPS = url.scheme?.lowercased() == "https"
        let connectEnd = isHTTPS ? (m?.secureConnectionStartDate ?? m?.connectEndDate) : m?.connectEndDate
        let connectDur = span(m?.connectStartDate, connectEnd)
        let tlsDur = span(m?.secureConnectionStartDate, m?.secureConnectionEndDate)
        let responseDur = span(m?.requestStartDate, m?.responseStartDate)

        var connect = StageResult(kind: .connect, state: .passed, duration: connectDur)
        var tls = StageResult(kind: .tls, state: isHTTPS ? .passed : .unsupported, duration: tlsDur, detail: isHTTPS ? nil : "Not a secure (https) address")
        var http = StageResult(kind: .http, state: .passed, duration: responseDur, detail: status.map { "Status \($0)" })

        if let failure {
            let timedOut = failure.code == .timedOut
            switch failure.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
                tls = StageResult(kind: .tls, state: .failed, duration: tlsDur, detail: failure.localizedDescription)
                http = StageResult(kind: .http, state: .skipped)
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed:
                connect = StageResult(kind: .connect, state: .failed, duration: connectDur, detail: failure.localizedDescription)
                tls = StageResult(kind: .tls, state: .skipped)
                http = StageResult(kind: .http, state: .skipped)
            default:
                if m?.connectEndDate == nil {
                    connect = StageResult(kind: .connect, state: timedOut ? .timedOut : .failed, duration: connectDur, detail: failure.localizedDescription)
                    tls = StageResult(kind: .tls, state: .skipped)
                    http = StageResult(kind: .http, state: .skipped)
                } else if isHTTPS && m?.secureConnectionEndDate == nil {
                    tls = StageResult(kind: .tls, state: timedOut ? .timedOut : .failed, duration: tlsDur, detail: failure.localizedDescription)
                    http = StageResult(kind: .http, state: .skipped)
                } else {
                    http = StageResult(kind: .http, state: timedOut ? .timedOut : .failed, duration: responseDur, detail: failure.localizedDescription)
                }
            }
        } else if let expected = endpoint.expectedStatus, status != expected {
            http = StageResult(kind: .http, state: .failed, duration: responseDur, detail: "Expected status \(expected), got \(status.map(String.init) ?? "none")")
        } else if endpoint.expectedStatus == nil, let status, !(200..<400).contains(status) {
            http = StageResult(kind: .http, state: .failed, duration: responseDur, detail: "Status \(status)")
        }
        return ([connect, tls, http], status, count)
    }
}

public struct InterfaceCounters: Sendable, Equatable {
    public var received: UInt64
    public var sent: UInt64

    public static func read() -> InterfaceCounters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = ifa.ifa_data else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            rx &+= UInt64(stats.ifi_ibytes)
            tx &+= UInt64(stats.ifi_obytes)
        }
        return InterfaceCounters(received: rx, sent: tx)
    }

    public static func rate(from a: InterfaceCounters, to b: InterfaceCounters, seconds: TimeInterval) -> (down: Double, up: Double)? {
        guard seconds > 0, b.received >= a.received, b.sent >= a.sent else { return nil }
        return (Double(b.received - a.received) / seconds, Double(b.sent - a.sent) / seconds)
    }
}

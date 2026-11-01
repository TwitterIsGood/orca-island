import Darwin
import Foundation

@main
enum HTTPServerTests {
    static var checks = 0
    static var eventCalls = 0
    static var pendingAcceptance: ((Bool) -> Void)?

    static func main() throws {
        let port = unusedPort()
        expect(port != 17777, "The HTTP harness does not touch the running companion")
        let server = try LocalHTTPServer(port: port, statusHandler: { complete in
            expect(Thread.isMainThread, "Status diagnostics are collected on the main thread")
            complete(Data(#"{"mode":"event","pollCount":2}"#.utf8))
        }, eventHandler: { data, complete in
            expect(Thread.isMainThread, "Events are handled on the main thread")
            eventCalls += 1
            switch String(decoding: data, as: UTF8.self) {
            case "accept": complete(true)
            case "reject": complete(false)
            case "duplicate": complete(true); complete(false)
            case "defer", "timeout", "stop": pendingAcceptance = complete
            default: complete(false)
            }
        })
        server.start()

        let health = request(port, "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        expect(health.hasPrefix("HTTP/1.1 200 OK"), "The health route remains available")
        expect(health.hasSuffix("\r\n\r\nok"), "The health response remains exactly ok")
        let status = request(port, "GET /status HTTP/1.1\r\nHost: localhost\r\n\r\n")
        expect(status.contains("Content-Type: application/json\r\n"), "Status advertises JSON")
        expect(status.hasSuffix(#"{"mode":"event","pollCount":2}"#), "Status returns only the supplied diagnostic bytes")

        let delayed = connect(port)
        send(delayed, post("defer"))
        pumpUntil { pendingAcceptance != nil }
        var byte: UInt8 = 0
        let earlyBytes = Darwin.recv(delayed, &byte, 1, MSG_DONTWAIT)
        expect(earlyBytes == -1 && (errno == EAGAIN || errno == EWOULDBLOCK), "No response is sent before event processing completes")
        pendingAcceptance?(true)
        pendingAcceptance = nil
        let accepted = collect(delayed)
        Darwin.close(delayed)
        expect(accepted.hasPrefix("HTTP/1.1 204 No Content"), "A processed event is acknowledged with 204")
        expect(request(port, post("reject")).hasPrefix("HTTP/1.1 400 Bad Request"), "Rejected events are never acknowledged as successful")
        let duplicate = request(port, post("duplicate"))
        expect(duplicate.components(separatedBy: "HTTP/1.1 ").count == 2, "Duplicate completion calls produce only one response")
        expect(duplicate.hasPrefix("HTTP/1.1 204 No Content"), "The first completion determines the response")

        let callsBeforeInvalidRequests = eventCalls
        expect(request(port, "POST /events HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n").hasPrefix("HTTP/1.1 413"), "Oversized bodies are refused before allocation")
        expect(request(port, "GET /health HTTP/1.1\r\nX-Huge: " + String(repeating: "x", count: 17000) + "\r\n\r\n").hasPrefix("HTTP/1.1 431"), "Oversized headers remain limited")
        expect(request(port, "POST /events HTTP/1.1\r\nContent-Length: 6\r\nContent-Length: 6\r\n\r\naccept").hasPrefix("HTTP/1.1 400"), "Ambiguous duplicate lengths are rejected")
        expect(request(port, "POST /events HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").hasPrefix("HTTP/1.1 400"), "Unsupported transfer encodings are rejected")
        expect(eventCalls == callsBeforeInvalidRequests, "Invalid requests never reach the application handler")

        let timedOut = connect(port)
        send(timedOut, post("timeout"))
        pumpUntil { pendingAcceptance != nil }
        let timeoutStart = Date()
        let timeoutResponse = collect(timedOut)
        expect(timeoutResponse.hasPrefix("HTTP/1.1 503 Service Unavailable"), "A handler that never completes times out with 503")
        expect(Date().timeIntervalSince(timeoutStart) >= 2.5, "Handler timeout waits for the three-second processing budget")
        pendingAcceptance?(true)
        pendingAcceptance = nil
        Darwin.close(timedOut)

        let stopped = connect(port)
        send(stopped, post("stop"))
        pumpUntil { pendingAcceptance != nil }
        server.stop()
        expect(collect(stopped).isEmpty, "Stopping the server closes active requests without a false acknowledgement")
        pendingAcceptance?(true)
        pendingAcceptance = nil
        Darwin.close(stopped)

        // Rebinding the same random port also verifies stop released its listener.
        let defaultPort = port
        let defaults = try LocalHTTPServer(port: defaultPort, eventHandler: { _, complete in complete(false) })
        defaults.start()
        expect(request(defaultPort, "GET /status HTTP/1.1\r\n\r\n").hasSuffix("\r\n\r\n{}"), "The default status handler exposes no data")
        defaults.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        print("HTTP server checks passed (\(checks) assertions); localhost random ports only.")
    }

    static func post(_ body: String) -> String {
        "POST /events HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    }

    static func unusedPort() -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        precondition(descriptor >= 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        precondition(result == 0)
        return UInt16(bigEndian: address.sin_port)
    }

    static func connect(_ port: UInt16) -> Int32 {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            precondition(descriptor >= 0)
            var noSigPipe: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return descriptor }
            Darwin.close(descriptor)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        preconditionFailure("The isolated test server did not listen on its random port")
    }

    static func send(_ descriptor: Int32, _ request: String) {
        let bytes = Array(request.utf8)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let written = Darwin.send(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                precondition(written > 0, "Could not send test request")
                offset += written
            }
        }
    }

    static func collect(_ descriptor: Int32) -> String {
        let deadline = Date().addingTimeInterval(5)
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let count = Darwin.recv(descriptor, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 { response.append(contentsOf: bytes.prefix(count)); continue }
            if count == 0 { return String(decoding: response, as: UTF8.self) }
            precondition(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR, "Unexpected receive error \(errno)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        preconditionFailure("Test response did not finish in five seconds")
    }

    static func request(_ port: UInt16, _ request: String) -> String {
        let descriptor = connect(port)
        defer { Darwin.close(descriptor) }
        send(descriptor, request)
        return collect(descriptor)
    }

    static func pumpUntil(_ ready: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !ready(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
        expect(ready(), "The application received the request before its deadline")
    }

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }
}

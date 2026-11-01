import Foundation
import Network

final class LocalHTTPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.orca-island.http")
    private let eventHandler: (Data) -> Void

    init(port: UInt16, eventHandler: @escaping (Data) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "OrcaIsland", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        self.listener = try NWListener(using: .tcp, on: endpointPort)
        self.eventHandler = eventHandler
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    func start() {
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            if let headerEnd = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = nextBuffer.subdata(in: 0..<headerEnd.lowerBound)
                let bodyStart = headerEnd.upperBound
                let headerText = String(decoding: header, as: UTF8.self)
                let requestLine = headerText.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
                let contentLength = headerText.split(separator: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0

                guard nextBuffer.count >= bodyStart + contentLength else {
                    self?.receive(on: connection, buffer: nextBuffer)
                    return
                }

                let body = nextBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                if requestLine.hasPrefix("POST /events") && !body.isEmpty {
                    self?.eventHandler(body)
                }
                let responseBody = requestLine.hasPrefix("GET /health") ? "ok" : ""
                let status = requestLine.hasPrefix("GET /health") ? "200 OK" : "204 No Content"
                let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self?.receive(on: connection, buffer: nextBuffer)
        }
    }
}

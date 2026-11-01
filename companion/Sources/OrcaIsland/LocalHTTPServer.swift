import Foundation
import Network

final class LocalHTTPServer {
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumBodyBytes = 1024 * 1024
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.orca-island.http")
    private let eventHandler: (Data) -> Void

    init(port: UInt16, eventHandler: @escaping (Data) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "OrcaIsland", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        self.listener = try NWListener(using: parameters)
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
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard nextBuffer.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else {
                self.respond(on: connection, status: "413 Payload Too Large")
                return
            }

            if let headerEnd = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                guard headerEnd.upperBound <= Self.maximumHeaderBytes else {
                    self.respond(on: connection, status: "431 Request Header Fields Too Large")
                    return
                }
                let header = nextBuffer.subdata(in: 0..<headerEnd.lowerBound)
                let bodyStart = headerEnd.upperBound
                let headerText = String(decoding: header, as: UTF8.self)
                let lines = headerText.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").split(separator: " ")
                let lengthHeaders = lines.dropFirst().filter { $0.lowercased().hasPrefix("content-length:") }
                guard request.count == 3, request[2].hasPrefix("HTTP/1."), lengthHeaders.count <= 1,
                      !lines.dropFirst().contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else {
                    self.respond(on: connection, status: "400 Bad Request")
                    return
                }

                var contentLength = 0
                if let lengthHeader = lengthHeaders.first {
                    let value = lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                          let length = Int(value), length <= Self.maximumBodyBytes else {
                        self.respond(on: connection, status: "400 Bad Request")
                        return
                    }
                    contentLength = length
                }

                guard nextBuffer.count >= bodyStart + contentLength else {
                    if isComplete {
                        self.respond(on: connection, status: "400 Bad Request")
                    } else {
                        self.receive(on: connection, buffer: nextBuffer)
                    }
                    return
                }

                let body = nextBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                if request[0] == "POST", request[1] == "/events", !body.isEmpty {
                    self.eventHandler(body)
                    self.respond(on: connection, status: "204 No Content")
                } else if request[0] == "GET", request[1] == "/health" {
                    self.respond(on: connection, status: "200 OK", body: "ok")
                } else {
                    self.respond(on: connection, status: "404 Not Found")
                }
                return
            }

            if nextBuffer.count >= Self.maximumHeaderBytes {
                self.respond(on: connection, status: "431 Request Header Fields Too Large")
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: nextBuffer)
            }
        }
    }

    private func respond(on connection: NWConnection, status: String, body: String = "") {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

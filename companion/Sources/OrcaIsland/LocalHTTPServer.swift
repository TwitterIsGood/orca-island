import Foundation
import Network

final class LocalHTTPServer {
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumBodyBytes = 1024 * 1024
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.orca-island.http")
    private let eventHandler: (Data, @escaping (Bool) -> Void) -> Void
    private let statusHandler: (@escaping (Data) -> Void) -> Void
    private var clients: [UUID: Client] = [:]
    private var stopped = false

    private final class Client {
        let id = UUID()
        let connection: NWConnection
        var responseStarted = false
        var timeout: DispatchWorkItem?

        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(port: UInt16,
         statusHandler: @escaping (@escaping (Data) -> Void) -> Void = { $0(Data("{}".utf8)) },
         eventHandler: @escaping (Data, @escaping (Bool) -> Void) -> Void) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "OrcaIsland", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        self.listener = try NWListener(using: parameters)
        self.eventHandler = eventHandler
        self.statusHandler = statusHandler
        self.listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.accept(connection)
        }
    }

    func start() {
        listener.start(queue: queue)
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.listener.cancel()
            for client in Array(self.clients.values) { self.close(client) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.respond(to: client, status: "503 Service Unavailable")
        }
        client.timeout = timeout
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
        receive(from: client, buffer: Data())
    }

    private func receive(from client: Client, buffer: Data) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { client.connection.cancel(); return }
            guard self.clients[client.id] != nil, !client.responseStarted else { return }
            guard error == nil else { self.close(client); return }
            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }
            guard nextBuffer.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else {
                self.respond(to: client, status: "413 Payload Too Large")
                return
            }

            if let headerEnd = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                guard headerEnd.upperBound <= Self.maximumHeaderBytes else {
                    self.respond(to: client, status: "431 Request Header Fields Too Large")
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
                    self.respond(to: client, status: "400 Bad Request")
                    return
                }

                var contentLength = 0
                if let lengthHeader = lengthHeaders.first {
                    let value = lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                          let length = Int(value) else {
                        self.respond(to: client, status: "400 Bad Request")
                        return
                    }
                    guard length <= Self.maximumBodyBytes else {
                        self.respond(to: client, status: "413 Payload Too Large")
                        return
                    }
                    contentLength = length
                }

                guard nextBuffer.count >= bodyStart + contentLength else {
                    if isComplete {
                        self.respond(to: client, status: "400 Bad Request")
                    } else {
                        self.receive(from: client, buffer: nextBuffer)
                    }
                    return
                }

                let body = nextBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                if request[0] == "POST", request[1] == "/events", !body.isEmpty {
                    DispatchQueue.main.async { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.eventHandler(body) { [weak self, weak client] accepted in
                            guard let self, let client else { return }
                            self.queue.async {
                                self.respond(to: client, status: accepted ? "204 No Content" : "400 Bad Request")
                            }
                        }
                    }
                } else if request[0] == "GET", request[1] == "/health" {
                    self.respond(to: client, status: "200 OK", body: Data("ok".utf8))
                } else if request[0] == "GET", request[1] == "/status" {
                    DispatchQueue.main.async { [weak self, weak client] in
                        guard let self, let client else { return }
                        self.statusHandler { [weak self, weak client] body in
                            guard let self, let client else { return }
                            self.queue.async {
                                self.respond(to: client, status: "200 OK", body: body,
                                             contentType: "application/json")
                            }
                        }
                    }
                } else {
                    self.respond(to: client, status: "404 Not Found")
                }
                return
            }

            if nextBuffer.count >= Self.maximumHeaderBytes {
                self.respond(to: client, status: "431 Request Header Fields Too Large")
            } else if isComplete {
                self.close(client)
            } else {
                self.receive(from: client, buffer: nextBuffer)
            }
        }
    }

    private func respond(to client: Client, status: String, body: Data = Data(),
                         contentType: String = "text/plain") {
        guard clients[client.id] != nil, !client.responseStarted, !stopped else { return }
        client.responseStarted = true
        client.timeout?.cancel()
        client.timeout = nil
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        client.connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            guard let self else { client.connection.cancel(); return }
            self.queue.async { self.close(client) }
        })
    }

    private func close(_ client: Client) {
        clients.removeValue(forKey: client.id)
        client.timeout?.cancel()
        client.timeout = nil
        client.connection.cancel()
    }
}

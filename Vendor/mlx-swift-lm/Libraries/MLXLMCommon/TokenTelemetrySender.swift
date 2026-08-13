import Foundation
import Network

public final class TokenTelemetrySender {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.apple.mlx.telemetry")

    public init(host: String = "127.0.0.1", port: UInt16 = 8000) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(integerLiteral: port))
        self.connection = NWConnection(to: endpoint, using:.udp)
        self.connection.start(queue: queue)
    }

    public func sendToken(token: Int, timestamp: TimeInterval) {
        // Format: "token,timestamp"
        let message = "\(token),\(timestamp)"
        let data = message.data(using:.utf8)
        connection.send(content: data, completion:.contentProcessed({ _ in }))
    }
}

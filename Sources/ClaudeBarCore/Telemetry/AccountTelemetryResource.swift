import Foundation

extension ClaudeAccount {
    /// The resource every request for this account carries. `service.name` is `claudebar` for
    /// all accounts (only file names tell them apart), `account.id` is always written, and
    /// `account.name` only when the email is known.
    public func telemetryResource(version: String, hostName: String) -> OTLP.Resource {
        var attributes: [OTLP.KeyValue] = [
            .init("service.name", .string("claudebar")),
            .init("service.version", .string(version)),
            .init("host.name", .string(hostName)),
            .init("os.type", .string("darwin")),
            .init("bar.spec.version", .string(TelemetryStamp.specVersion)),
            .init("account.id", .string(id)),
        ]
        if let email, !email.isEmpty {
            attributes.append(.init("account.name", .string(email)))
        }
        return OTLP.Resource(attributes: attributes)
    }
}

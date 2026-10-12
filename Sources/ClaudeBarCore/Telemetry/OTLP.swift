import Foundation

/// The subset of OpenTelemetry's OTLP/JSON encoding this app writes. Hand-rolled so the
/// app stays dependency-free; field names and value encodings follow the OTLP JSON mapping
/// (lowerCamelCase keys, 64-bit integers and nanosecond timestamps as decimal strings, enums
/// as numbers), which is what the Collector's `otlpjsonfile` receiver and OTLP/HTTP accept.
public enum OTLP {
    public enum AnyValue: Encodable, Sendable, Equatable {
        case string(String)
        case int(Int64)
        case double(Double)
        case bool(Bool)

        private enum CodingKeys: String, CodingKey {
            case stringValue, intValue, doubleValue, boolValue
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .string(let value): try container.encode(value, forKey: .stringValue)
            // OTLP JSON carries int64 as a string so consumers in languages without 64-bit
            // integers (JavaScript) don't lose precision.
            case .int(let value): try container.encode(String(value), forKey: .intValue)
            case .double(let value): try container.encode(value, forKey: .doubleValue)
            case .bool(let value): try container.encode(value, forKey: .boolValue)
            }
        }
    }

    public struct KeyValue: Encodable, Sendable, Equatable {
        public let key: String
        public let value: AnyValue

        public init(_ key: String, _ value: AnyValue) {
            self.key = key
            self.value = value
        }
    }

    public struct Resource: Encodable, Sendable {
        public let attributes: [KeyValue]

        public init(attributes: [KeyValue]) {
            self.attributes = attributes
        }
    }

    public struct Scope: Encodable, Sendable {
        public let name: String
        public let version: String

        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    // MARK: Metrics

    public struct NumberDataPoint: Encodable, Sendable {
        public enum Value: Sendable, Equatable {
            case int(Int64)
            case double(Double)
        }

        public let attributes: [KeyValue]
        public let startTime: Date?
        public let time: Date
        public let value: Value

        public init(attributes: [KeyValue], startTime: Date? = nil, time: Date, value: Value) {
            self.attributes = attributes
            self.startTime = startTime
            self.time = time
            self.value = value
        }

        private enum CodingKeys: String, CodingKey {
            case attributes, startTimeUnixNano, timeUnixNano, asInt, asDouble
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(attributes, forKey: .attributes)
            if let startTime {
                try container.encode(OTLP.unixNano(startTime), forKey: .startTimeUnixNano)
            }
            try container.encode(OTLP.unixNano(time), forKey: .timeUnixNano)
            switch value {
            case .int(let int): try container.encode(String(int), forKey: .asInt)
            case .double(let double): try container.encode(double, forKey: .asDouble)
            }
        }
    }

    public struct Metric: Encodable, Sendable {
        public enum Kind: Sendable {
            case gauge
            /// A monotonic cumulative counter: each point is the running total since `startTime`.
            case cumulativeSum
        }

        public let name: String
        public let unit: String
        public let description: String
        public let kind: Kind
        public let dataPoints: [NumberDataPoint]

        public init(name: String, unit: String, description: String, kind: Kind, dataPoints: [NumberDataPoint]) {
            self.name = name
            self.unit = unit
            self.description = description
            self.kind = kind
            self.dataPoints = dataPoints
        }

        private enum CodingKeys: String, CodingKey {
            case name, unit, description, gauge, sum
        }

        private struct Gauge: Encodable {
            let dataPoints: [NumberDataPoint]
        }

        private struct Sum: Encodable {
            let dataPoints: [NumberDataPoint]
            // AGGREGATION_TEMPORALITY_CUMULATIVE
            let aggregationTemporality = 2
            let isMonotonic = true
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(unit, forKey: .unit)
            try container.encode(description, forKey: .description)
            switch kind {
            case .gauge: try container.encode(Gauge(dataPoints: dataPoints), forKey: .gauge)
            case .cumulativeSum: try container.encode(Sum(dataPoints: dataPoints), forKey: .sum)
            }
        }
    }

    /// One `ExportMetricsServiceRequest`: a single resource with a single scope.
    public struct MetricsRequest: Encodable, Sendable {
        public let resource: Resource
        public let scope: Scope
        public let metrics: [Metric]

        public init(resource: Resource, scope: Scope, metrics: [Metric]) {
            self.resource = resource
            self.scope = scope
            self.metrics = metrics
        }

        private struct ResourceMetrics: Encodable {
            let resource: Resource
            let scopeMetrics: [ScopeMetrics]
        }

        private struct ScopeMetrics: Encodable {
            let scope: Scope
            let metrics: [Metric]
        }

        private enum CodingKeys: String, CodingKey {
            case resourceMetrics
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                [ResourceMetrics(resource: resource, scopeMetrics: [ScopeMetrics(scope: scope, metrics: metrics)])],
                forKey: .resourceMetrics
            )
        }
    }

    // MARK: Logs

    public struct LogRecord: Encodable, Sendable {
        public let time: Date
        public let eventName: String
        public let body: String
        public let attributes: [KeyValue]

        public init(time: Date, eventName: String, body: String, attributes: [KeyValue]) {
            self.time = time
            self.eventName = eventName
            self.body = body
            self.attributes = attributes
        }

        private enum CodingKeys: String, CodingKey {
            case timeUnixNano, observedTimeUnixNano, severityNumber, severityText, eventName, body, attributes
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            let nanos = OTLP.unixNano(time)
            try container.encode(nanos, forKey: .timeUnixNano)
            try container.encode(nanos, forKey: .observedTimeUnixNano)
            // SEVERITY_NUMBER_INFO: these are state changes, never failures.
            try container.encode(9, forKey: .severityNumber)
            try container.encode("INFO", forKey: .severityText)
            // The Bar Telemetry Spec reads the name from this field only, never an attribute.
            try container.encode(eventName, forKey: .eventName)
            try container.encode(AnyValue.string(body), forKey: .body)
            try container.encode(attributes, forKey: .attributes)
        }
    }

    /// One `ExportLogsServiceRequest`: a single resource with a single scope.
    public struct LogsRequest: Encodable, Sendable {
        public let resource: Resource
        public let scope: Scope
        public let logRecords: [LogRecord]

        public init(resource: Resource, scope: Scope, logRecords: [LogRecord]) {
            self.resource = resource
            self.scope = scope
            self.logRecords = logRecords
        }

        private struct ResourceLogs: Encodable {
            let resource: Resource
            let scopeLogs: [ScopeLogs]
        }

        private struct ScopeLogs: Encodable {
            let scope: Scope
            let logRecords: [LogRecord]
        }

        private enum CodingKeys: String, CodingKey {
            case resourceLogs
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(
                [ResourceLogs(resource: resource, scopeLogs: [ScopeLogs(scope: scope, logRecords: logRecords)])],
                forKey: .resourceLogs
            )
        }
    }

    static func unixNano(_ date: Date) -> String {
        // Millisecond precision is all Date reliably carries; scale up in integer space so
        // the string never picks up floating-point noise in its low digits.
        let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
        return String(millis * 1_000_000)
    }

    /// Single-line JSON for the line-delimited file format: one request per line.
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}

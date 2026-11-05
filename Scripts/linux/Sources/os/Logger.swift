// Minimal stand-in for Apple's os.Logger: same call shapes, writes nothing.
public struct OSLogPrivacy: Sendable { public static let `public` = OSLogPrivacy(), `private` = OSLogPrivacy(), auto = OSLogPrivacy() }

public struct OSLogMessage: ExpressibleByStringInterpolation, Sendable {
    public struct StringInterpolation: StringInterpolationProtocol {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ s: String) { text += s }
        public mutating func appendInterpolation<T>(_ v: @autoclosure () -> T, privacy: OSLogPrivacy = .auto) { text += "\(v())" }
    }
    let text: String
    public init(stringLiteral s: String) { text = s }
    public init(stringInterpolation i: StringInterpolation) { text = i.text }
}

public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func debug(_ m: OSLogMessage) {}
    public func info(_ m: OSLogMessage) {}
    public func notice(_ m: OSLogMessage) {}
    public func error(_ m: OSLogMessage) {}
    public func warning(_ m: OSLogMessage) {}
    public func fault(_ m: OSLogMessage) {}
}

public struct UncheckedSendableBox<Value>: @unchecked Sendable {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }
}

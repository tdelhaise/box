import Foundation

struct QueueMetrics {
    var count: Int
    var objectCount: Int
    var freeBytes: UInt64?

    static var zero: QueueMetrics {
        QueueMetrics(count: 0, objectCount: 0, freeBytes: nil)
    }
}
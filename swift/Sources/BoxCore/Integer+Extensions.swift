
import Foundation

internal extension UInt16 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }
}

internal extension UInt32 {
    var bigEndianBytes: [UInt8] {
        let value = self.bigEndian
        return [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }
}

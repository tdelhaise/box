import NIOCore

enum BoxAdminChannelHandle {
    case nio(Channel)
    #if os(Windows)
    case pipe(BoxAdminNamedPipeServer)
    #endif
}

extension BoxAdminChannelHandle: @unchecked Sendable {}

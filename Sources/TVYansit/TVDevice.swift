import Foundation

/// Yayin yapilabilecek TV: DLNA oynaticisi ya da Google Cast cihazi.
struct TVDevice: Identifiable, Hashable {
    enum Kind: Hashable {
        case dlna(DLNADevice)
        case cast(CastDevice)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .dlna(let device): return "dlna:\(device.id)"
        case .cast(let device): return "cast:\(device.id)"
        }
    }

    var name: String {
        switch kind {
        case .dlna(let device): return device.name
        case .cast(let device): return device.name
        }
    }

    var model: String {
        switch kind {
        case .dlna(let device): return device.model
        case .cast(let device): return device.model
        }
    }

    var protocolName: String {
        switch kind {
        case .dlna: return "DLNA"
        case .cast: return "Cast"
        }
    }

    var supportsVolume: Bool {
        switch kind {
        case .dlna(let device): return device.renderingControlURL != nil
        case .cast: return true
        }
    }

    var isCast: Bool {
        if case .cast = kind { return true }
        return false
    }
}

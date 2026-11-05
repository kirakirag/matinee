// Linux-only: Darwin APIs MatineeKit uses that swift-corelibs-foundation lacks.
import Foundation

extension URL {
    static var applicationSupportDirectory: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var cachesDirectory: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
}

/// JSONSerialization boxes booleans as NSNumber with objCType "c".
func CFGetTypeID(_ n: NSNumber) -> Int { String(cString: n.objCType) == "c" ? 1 : 0 }
func CFBooleanGetTypeID() -> Int { 1 }

import Foundation
import Virtualization
import DeskBoxCore

/// VZ delegate 只报告平台事件，不直接把平台状态提升为产品 Running。
/// guestDidStop / didStopWithError 都必须收紧产品生命周期。
final class VZRuntimeDelegate: NSObject, VZVirtualMachineDelegate {
    let onGuestStopped: @Sendable (NSError?) -> Void

    init(onGuestStopped: @escaping @Sendable (NSError?) -> Void) {
        self.onGuestStopped = onGuestStopped
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onGuestStopped(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onGuestStopped(error as NSError)
    }
}

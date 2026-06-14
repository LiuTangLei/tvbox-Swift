#if os(iOS)
import UIKit

enum IOSOrientationController {
    private static var lastRequestedOrientation: UIInterfaceOrientationMask?

    static func requestLandscape() {
        request(.landscape)
    }

    static func requestPortrait() {
        request(.portrait)
    }

    static var isLandscapeActive: Bool {
        currentInterfaceOrientation?.isLandscape == true
    }

    private static func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        if lastRequestedOrientation == orientations,
           scene.interfaceOrientation.matches(orientations) {
            return
        }
        lastRequestedOrientation = orientations

        scene.windows.first { $0.isKeyWindow }?
            .rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }

    private static var currentInterfaceOrientation: UIInterfaceOrientation? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation
    }
}

private extension UIInterfaceOrientation {
    func matches(_ mask: UIInterfaceOrientationMask) -> Bool {
        switch self {
        case .portrait, .portraitUpsideDown:
            return mask.contains(.portrait) || mask.contains(.portraitUpsideDown)
        case .landscapeLeft:
            return mask.contains(.landscapeLeft)
        case .landscapeRight:
            return mask.contains(.landscapeRight)
        case .unknown:
            return false
        @unknown default:
            return false
        }
    }
}
#endif

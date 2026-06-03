import UIKit
import NMapsMap

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Settings.app 토글 기본값 등록 — 사용자가 설정 앱을 한 번도 안 열어도 false 로 동작.
        UserDefaults.standard.register(defaults: [DebugSettings.fullRouteOverlayKey: false])

        if let path = Bundle.main.path(forResource: "Secrets", ofType: "plist"),
           let secrets = NSDictionary(contentsOfFile: path),
           let key = secrets["NaverMapKey"] as? String {
            NMFAuthManager.shared().ncpKeyId = key
        }

        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: MapViewController())
        window?.rootViewController = nav
        window?.overrideUserInterfaceStyle = .light
        window?.makeKeyAndVisible()
        return true
    }
}

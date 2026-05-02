import UIKit
import NMapsMap

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
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

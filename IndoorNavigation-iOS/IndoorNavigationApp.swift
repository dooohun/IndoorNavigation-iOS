import UIKit
import NMapsMap

class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NMFAuthManager.shared().ncpKeyId = "rze1uktvon"

        window = UIWindow(frame: UIScreen.main.bounds)
        let nav = UINavigationController(rootViewController: MapViewController())
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
        return true
    }
}

import UIKit

enum Theme {
    static let accent = UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    static let background = UIColor(red: 0.98, green: 0.976, blue: 0.96, alpha: 1)
    static let userBubble = UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1)
    static let text = UIColor(white: 0.12, alpha: 1)
    static let secondaryText = UIColor(white: 0.45, alpha: 1)
    static let codeBackground = UIColor(white: 0.92, alpha: 1)
    static let error = UIColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1)
}

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UINavigationBar.appearance().tintColor = Theme.accent
        UINavigationBar.appearance().barTintColor = Theme.background

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.tintColor = Theme.accent
        let nav = UINavigationController(rootViewController: ConversationListViewController())
        window.rootViewController = nav
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        ConversationStore.shared.save()
    }
}

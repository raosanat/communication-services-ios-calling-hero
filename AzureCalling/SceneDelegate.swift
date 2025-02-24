//
//  Copyright (c) Microsoft Corporation. All rights reserved.
//  Licensed under the MIT License.
//

import UIKit
import MSAL

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    var authHandler: AADAuthHandler?
    var introViewController: IntroViewController?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        guard (scene as? UIWindowScene) != nil else {
            return
        }

        // Inject dependencies to IntroViewController
        if let navigationViewController = window?.rootViewController as? UINavigationController,
           let introViewController = navigationViewController.visibleViewController as? IntroViewController,
           let appDelegate = UIApplication.shared.delegate as? AppDelegate {

            authHandler = appDelegate.authHandler
            introViewController.authHandler = authHandler
            introViewController.createCallingContextFunction = { () -> CallingContext in
                return CallingContext(tokenFetcher: appDelegate.tokenService.getCommunicationToken)
            }
            self.introViewController = introViewController
        }

        guard let urlContext = connectionOptions.urlContexts.first else {
            return
        }

        _ = launchMeetingsUrl(urlContext.url)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release any resources associated with this scene that can be re-created the next time the scene connects.
        // The scene may re-connect later, as its session was not necessarily discarded (see `application:didDiscardSceneSessions` instead).
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Called when the scene has moved from an inactive state to an active state.
        // Use this method to restart any tasks that were paused (or not yet started) when the scene was inactive.
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when the scene will move from an active state to an inactive state.
        // This may occur due to temporary interruptions (ex. an incoming phone call).
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Use this method to save data, release shared resources, and store enough scene-specific state information
        // to restore the scene back to its current state.
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let urlContext = URLContexts.first else {
            return
        }

        if launchMeetingsUrl(urlContext.url) {
            print("Successfully handled teams meeting url")
        } else {
            handleMSALResponse(urlContext)
        }
    }

    // MARK: Private Functions

    private func handleMSALResponse(_ urlContext: UIOpenURLContext) {
        // Required for AAD Authentication

        let url = urlContext.url
        let sourceApp = urlContext.options.sourceApplication

        MSALPublicClientApplication.handleMSALResponse(url, sourceApplication: sourceApp)
    }

    private func launchMeetingsUrl(_ url: URL) -> Bool {
        let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true)
        guard let params = components!.queryItems else {
                print("Invalid URL, exiting")
                return false
        }

        guard let meetingUrl = params.first(where: { $0.name == "meeting" })?.value else {
            return false
        }

        self.introViewController?.meetingLinkFromUniversalLink = URL(string: meetingUrl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!.absoluteString
        self.introViewController?.performSegue(withIdentifier: "JoinCall", sender: nil)
        return true
    }
}

import SwiftUI
import AVFoundation
import UserNotifications

// MARK: – AppDelegate (configure audio session for background playback)
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Catégorie seulement : la session n'est activée qu'à l'ouverture d'un
        // lecteur (PlaybackAudio). Activée ici, elle coupait la musique des
        // autres apps dès le lancement, même sans rien lire.
        PlaybackAudio.configure()
        // Notifications de live : tâche d'arrière-plan et réception des touches.
        LiveNotifier.register()
        UNUserNotificationCenter.current().delegate = self
        // Live Activity restée d'une session précédente (app tuée en lecture).
        PlayerActivity.endOthers()
        // VODs en téléchargement : iOS rend à la session les fichiers arrivés.
        VodDownloader.shared.activate()
        return true
    }

    /// Fichiers d'une VOD arrivés pendant que l'app était fermée : iOS la
    /// relance en arrière-plan le temps de les ranger.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == VodDownloader.identifier else { completionHandler(); return }
        VodDownloader.shared.backgroundCompletion = completionHandler
        VodDownloader.shared.activate()
        Task { @MainActor in _ = VodDownloads.shared }
    }

    // Notification touchée → on ouvre le direct de la chaîne.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let login = response.notification.request.content.userInfo["login"] as? String {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openLiveChannel, object: nil, userInfo: ["login": login])
            }
        } else if response.notification.request.content.userInfo["feedback"] != nil {
            // Réponse à un retour : « Mes signalements ».
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openMyFeedback, object: nil)
            }
        }
        completionHandler()
    }

    // App ouverte : la notification s'affiche quand même en bannière.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Fermeture de l'app → purge du cache emotes/badges (si l'option est active).
    /// NB : on ne purge PAS en passant en arriere-plan, sinon revenir d'un
    /// changement d'app (ou du PiP) rechargerait tout pour rien.
    func applicationWillTerminate(_ application: UIApplication) {
        ImageCache.shared.purgeIfNeeded()
        // L'app fermée, la lecture s'arrête : sa Live Activity aussi, sinon
        // iOS la laisserait affichée des heures.
        PlayerActivity.end()
        PlayerActivity.endOthers(wait: true)
    }
}

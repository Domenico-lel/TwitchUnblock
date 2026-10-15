import SwiftUI
import WebKit

// MARK: – Login web Twitch (capture du cookie `auth-token`)
//
// L'API GQL « community points » (solde, coffres, rachats) n'accepte QUE les
// tokens liés au Client-ID web officiel `kimne78kx3ncx6brgo4mv6wki5h1ko`.
// Un token OAuth émis pour un Client-ID custom renvoie `communityPoints: null`.
//
// La seule façon d'obtenir un token compatible est de récupérer le cookie de
// session `auth-token` d'une vraie connexion twitch.tv. C'est ce que fait cette
// WebView : elle charge la page de login et capture le cookie une fois connecté.
//
// ⚠️ Non officiel / hors-ToS Twitch — réservé à l'usage perso de cette app.

private let kMobileUA =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
    + "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"

// MARK: – Sheet présentable
struct TwitchWebLoginSheet: View {
    /// true  → on efface d'abord les cookies twitch (re-login forcé, ex: token expiré)
    /// false → on réutilise la session existante (capture instantanée si déjà connecté)
    let clearSession: Bool
    /// Pseudo du compte de l'app : une connexion à un autre compte est refusée
    /// sur place, et la page de connexion revient pour le bon.
    var expectedLogin: String? = nil
    let onComplete: (_ token: String, _ login: String?) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    /// Pseudo du compte refusé (bandeau en haut de la feuille).
    @State private var wrongAccount: String? = nil
    /// Page de connexion impossible à charger (hors ligne, réseau coupé).
    @State private var loadFailed = false
    /// « Réessayer » : la page de connexion est rechargée à chaque hausse.
    @State private var reloadCount = 0

    /// Langue de l'app (la feuille est présentée sans le store).
    private var lang: Lang {
        Lang(rawValue: UserDefaults.standard.string(forKey: "lang") ?? "en") ?? .en
    }

    var body: some View {
        NavigationView {
            ZStack {
                Color.tDark.ignoresSafeArea()

                TwitchWebLogin(
                    clearSession: clearSession,
                    expectedLogin: expectedLogin,
                    reloadCount: reloadCount,
                    onComplete: onComplete,
                    onLoadingChange: {
                        isLoading = $0
                        if $0 { loadFailed = false }
                    },
                    onLoadFailed: { loadFailed = true },
                    onWrongAccount: { wrongAccount = $0 }
                )
                .ignoresSafeArea(edges: .bottom)

                if let wrong = wrongAccount {
                    VStack {
                        Text(wrongAccountText(wrong))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.tWarning.opacity(0.95))
                            .cornerRadius(10)
                            .padding(12)
                        Spacer()
                    }
                }

                if loadFailed {
                    // Sans réseau, le chargement ne finissait jamais : la roue
                    // tournait sans fin, seule sortie « Annuler ».
                    VStack(spacing: 14) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 30))
                            .foregroundColor(.tMuted)
                        Text(translate("web_load_failed", lang))
                            .font(.system(size: 14))
                            .foregroundColor(.tText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(translate("retry", lang)) {
                            loadFailed = false
                            isLoading = true
                            reloadCount += 1
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.tPrimary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.tDark)
                } else if isLoading {
                    VStack(spacing: 12) {
                        ProgressView().tint(.tPrimary).scaleEffect(1.3)
                        Text(translate("web_loading", lang))
                            .font(.system(size: 13))
                            .foregroundColor(.tMuted)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(translate("account_web", lang))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.tText)
                        Text(translate("web_login_sub", lang))
                            .font(.system(size: 10))
                            .foregroundColor(.tMuted)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(translate("cancel", lang)) { onCancel() }
                        .foregroundColor(.tPrimary)
                }
            }
        }
    }
}

extension TwitchWebLoginSheet {
    fileprivate func wrongAccountText(_ wrong: String) -> String {
        translate("web_wrong_account", lang)
            .replacingOccurrences(of: "{w}", with: wrong)
            .replacingOccurrences(of: "{a}", with: expectedLogin ?? "?")
    }
}

// MARK: – WKWebView wrapper
private struct TwitchWebLogin: UIViewRepresentable {
    let clearSession: Bool
    let expectedLogin: String?
    /// Hausse = la page de connexion est rechargée (« Réessayer »).
    let reloadCount: Int
    let onComplete: (_ token: String, _ login: String?) -> Void
    let onLoadingChange: (Bool) -> Void
    let onLoadFailed: () -> Void
    let onWrongAccount: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = kMobileUA
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)

        let load = {
            if let url = URL(string: "https://www.twitch.tv/login") {
                webView.load(URLRequest(url: url))
            }
        }

        if clearSession {
            let store = webView.configuration.websiteDataStore.httpCookieStore
            store.getAllCookies { cookies in
                let twitchCookies = cookies.filter { $0.domain.contains("twitch") }
                guard !twitchCookies.isEmpty else { load(); return }
                let group = DispatchGroup()
                for c in twitchCookies {
                    group.enter()
                    store.delete(c) { group.leave() }
                }
                group.notify(queue: .main) {
                    logger.debug("AUTH/WEB", "Cookies twitch effacés", "\(twitchCookies.count) supprimés")
                    load()
                }
            }
        } else {
            load()
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // « Réessayer » après un échec de chargement.
        guard context.coordinator.reloadCount != reloadCount else { return }
        context.coordinator.reloadCount = reloadCount
        if let url = URL(string: "https://www.twitch.tv/login") {
            uiView.load(URLRequest(url: url))
        }
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    // MARK: Coordinator
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: TwitchWebLogin
        private weak var webView: WKWebView?
        private var timer: Timer?
        private var done = false
        /// Mauvais compte en cours d'effacement : pas de capture entre-temps.
        private var resetting = false
        /// Dernier « Réessayer » traité (updateUIView).
        var reloadCount = 0

        init(_ parent: TwitchWebLogin) { self.parent = parent }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            // Filet de sécurité : certaines connexions SPA ne déclenchent pas didFinish.
            // Mode .common : le défilement de la page de connexion ne doit pas
            // suspendre la capture du cookie.
            timer = Timer.scheduledCommon(every: 1.2) { [weak self] _ in
                self?.captureToken()
            }
        }

        func stop() {
            timer?.invalidate(); timer = nil
        }

        // MARK: WKNavigationDelegate
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoadingChange(true)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoadingChange(false)
            captureToken()
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoadingChange(false)
        }
        /// Échec avant tout affichage (hors ligne, réseau coupé, wifi qui ne
        /// répond pas) : passait inaperçu, la roue tournait sans fin.
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            parent.onLoadingChange(false)
            let e = error as NSError
            // Seulement une panne réseau : un chargement remplacé par un autre
            // (redirection de la page de connexion, « Réessayer ») ou un lien
            // que la page ne sait pas ouvrir n'en sont pas.
            guard e.domain == NSURLErrorDomain,
                  e.code != NSURLErrorCancelled, e.code != NSURLErrorUnsupportedURL else { return }
            logger.warn("AUTH/WEB", "Page de connexion indisponible", e.localizedDescription)
            parent.onLoadFailed()
        }

        // MARK: Capture
        private func captureToken() {
            guard !done, !resetting, let webView = webView else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self, !self.done, !self.resetting else { return }
                guard let auth = cookies.first(where: { $0.name == "auth-token" })?.value,
                      auth.count >= 20 else { return }   // évite un cookie partiel/vide
                let login = cookies.first(where: { $0.name == "login" })?.value
                // Un autre compte que celui de l'app : refusé, cookies effacés,
                // et la page de connexion revient pour le bon.
                if let expected = self.parent.expectedLogin?.lowercased(), !expected.isEmpty,
                   let login, login.lowercased() != expected {
                    self.resetting = true
                    logger.warn("AUTH/WEB", "Mauvais compte refusé", "@\(login) ≠ @\(expected)")
                    let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
                    let group = DispatchGroup()
                    for c in cookies where c.domain.contains("twitch") {
                        group.enter()
                        cookieStore.delete(c) { group.leave() }
                    }
                    group.notify(queue: .main) {
                        self.parent.onWrongAccount(login)
                        if let url = URL(string: "https://www.twitch.tv/login") {
                            webView.load(URLRequest(url: url))
                        }
                        self.resetting = false
                    }
                    return
                }
                self.done = true
                self.stop()
                logger.success("AUTH/WEB", "Token de session capturé",
                               "@\(login ?? "?")")
                DispatchQueue.main.async { self.parent.onComplete(auth, login) }
            }
        }
    }
}

// MARK: – Fin de session web
enum TwitchWebSession {
    /// Efface les cookies et données twitch.tv de la WebView de connexion.
    /// Sans ça, après une déconnexion, la connexion web suivante reprenait
    /// en silence l'ancienne session (cookie `auth-token` toujours là).
    @MainActor
    static func clear() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let twitch = records.filter { $0.displayName.lowercased().contains("twitch") }
        guard !twitch.isEmpty else { return }
        await store.removeData(ofTypes: types, for: twitch)
        logger.info("AUTH/WEB", "Données twitch.tv effacées", "\(twitch.count) site(s)")
    }
}

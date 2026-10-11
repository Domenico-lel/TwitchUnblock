import SwiftUI

// ═══════════════════════════════════════════════════════════════════════════
//  Menu « ⋯ » du lecteur immersif : ce que la barre en surimpression ne peut
//  pas porter sans encombrer l'image.
// ═══════════════════════════════════════════════════════════════════════════

struct PlayerMenuSheet: View {
    let qualities: [String]
    let selected: String
    let canRewind: Bool
    /// On regarde déjà le DVR d'un direct : proposer le retour au direct.
    let isDvr: Bool

    var onSelectQuality: (String) -> Void = { _ in }
    var onRewind:      () -> Void = {}
    var onBackToLive:  () -> Void = {}
    var onSleepTimer:  () -> Void = {}
    var onSettings:    () -> Void = {}
    /// Signaler un problème : le formulaire, avec ce qui se lit.
    var onFeedback:    () -> Void = {}
    /// Direct : source qui sert le flux (« as », « al »…) ; nil hors direct.
    var liveSource: String? = nil
    /// Changer de source : le direct est relancé par elle.
    var onSelectSource: ((String) -> Void)? = nil
    /// VOD : télécharger un passage pour le regarder hors ligne.
    var onDownload: (() -> Void)? = nil

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.t("player_section")).font(.tSection).foregroundColor(.tText)
                Spacer()
                TIconButton(icon: "xmark") { dismiss() }
            }
            .padding(TSpace.lg)

            Divider().background(Color.tBorder)

            ScrollView {
                VStack(spacing: 0) {

                    // Qualité : le lecteur immersif n'a pas de sélecteur à l'écran,
                    // c'est ici qu'on change de piste.
                    if !qualities.isEmpty {
                        HStack(spacing: TSpace.md) {
                            Image(systemName: "film")
                                .font(.system(size: 15)).foregroundColor(.tPrimary)
                                .frame(width: 24)
                            Text(store.t("quality")).font(.tCardTitle).foregroundColor(.tText)
                            Spacer()
                        }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TSpace.sm) {
                                ForEach(qualities, id: \.self) { q in
                                    TChip(title: label(q), isOn: q == selected) {
                                        onSelectQuality(q)
                                    }
                                }
                            }
                            .padding(.horizontal, TSpace.lg)
                        }
                        .padding(.vertical, TSpace.sm)

                        divider
                    }

                    // Source du direct : le proxy qui sert le flux, et de quoi
                    // en changer (le direct repart aussitôt).
                    if let onSelectSource, let used = liveSource {
                        HStack(spacing: TSpace.md) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 15)).foregroundColor(.tPrimary)
                                .frame(width: 24)
                            Text(store.t("live_source")).font(.tCardTitle).foregroundColor(.tText)
                            Spacer()
                            Text(store.t("src_\(used)")).font(.tMeta).foregroundColor(.tMuted)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, TSpace.lg)
                        .padding(.top, TSpace.md)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: TSpace.sm) {
                                ForEach(kLiveSourceChoices, id: \.self) { id in
                                    TChip(title: store.t("src_\(id)"), isOn: id == store.liveSource) {
                                        onSelectSource(id)
                                    }
                                }
                            }
                            .padding(.horizontal, TSpace.lg)
                        }
                        .padding(.vertical, TSpace.sm)

                        divider
                    }

                    if isDvr {
                        row(icon: "dot.radiowaves.left.and.right",
                            title: store.t("back_to_live"),
                            tint: .tLive, action: onBackToLive)
                        divider
                    } else if canRewind {
                        row(icon: "gobackward", title: store.t("rewind"),
                            detail: store.t("rewind_sub"), action: onRewind)
                        divider
                    }

                    if let onDownload {
                        row(icon: "arrow.down.circle", title: store.t("dl_download"),
                            detail: store.t("dl_download_sub"), action: onDownload)
                        divider
                    }

                    row(icon: "moon.zzz.fill", title: store.t("sleep_timer"),
                        action: onSleepTimer)
                    divider
                    row(icon: "gearshape.fill", title: store.t("settings"),
                        action: onSettings)
                    divider
                    row(icon: "ladybug.fill", title: store.t("report_problem"),
                        tint: .tLive, action: onFeedback)
                }
                .padding(.vertical, TSpace.sm)
            }
        }
        .background(Color.tDark)
    }

    private func label(_ q: String) -> String {
        q.replacingOccurrences(of: "chunked", with: "Source")
         .replacingOccurrences(of: "source",  with: "Source")
    }

    private var divider: some View {
        Divider().background(Color.tBorder).padding(.leading, 56)
    }

    @ViewBuilder
    private func row(icon: String, title: String, detail: String? = nil,
                     tint: Color = .tPrimary, action: (() -> Void)? = nil) -> some View {
        let content = HStack(spacing: TSpace.md) {
            Image(systemName: icon)
                .font(.system(size: 15)).foregroundColor(tint).frame(width: 24)
            Text(title).font(.tCardTitle).foregroundColor(.tText)
            Spacer()
            if let detail {
                Text(detail).font(.tMeta).foregroundColor(.tMuted)
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.tMuted)
            }
        }
        .padding(.horizontal, TSpace.lg)
        .padding(.vertical, TSpace.md)
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

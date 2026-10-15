import SwiftUI

// MARK: – Hype train : approche, départ, niveau, fin
/// Contenu du bandeau du hype train, sur deux lignes au plus (portrait) :
/// - l'approche, comme le bandeau « Incoming » de Twitch : pastilles (deux,
///   trois pour un objectif > 5) dont la dernière se coche au départ, soutiens
///   qui manquent et compte à rebours ;
/// - le départ, puis le niveau en cours avec sa barre et son temps restant ;
/// - les messages courts (niveau terminé, fin) remplacent un moment ce
///   contenu au lieu d'ajouter une rangée.
/// Couleur fixe (`.tLive`) : celle de la chaîne arrive parfois vide.
struct HypeTrainCard: View {
    let hype: LiveEventsService.LiveHype
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String {
        switch hype.variant {
        case .golden:   return store.t("hype_golden")
        case .treasure: return store.t("hype_treasure")
        case .regular:  return store.t("hype_train")
        }
    }

    /// Approche, ou départ juste après elle (pastilles toutes cochées).
    private var showsApproach: Bool { hype.phase == .approaching || hype.flash == .kickoff }

    private var ended: (level: Int, percent: Int)? {
        if case .ended(let level, let percent)? = hype.flash { return (level: level, percent: percent) }
        return nil
    }

    private var levelDone: Int? {
        if case .levelDone(let n)? = hype.flash { return n }
        return nil
    }

    var body: some View {
        // Une seule lecture de l'heure : entre deux, la fin pourrait passer
        // et l'intervalle du compte à rebours s'inverser.
        let now = Date()
        VStack(alignment: .leading, spacing: 4) {
            if let e = ended {
                Text(endedText(e))
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                    .lineLimit(2)
            } else if hype.flash == .departed {
                HStack(spacing: 6) {
                    Text(store.t("hype_departed"))
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    countdown(now)
                }
                Text(store.t("hype_departed_sub"))
                    .font(.system(size: 10)).foregroundColor(.tMuted)
                    .lineLimit(1)
            } else if showsApproach {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                        .lineLimit(1)
                    Text(store.t("hype_incoming"))
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.tLive)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.tLive.opacity(0.15)).cornerRadius(5)
                    Spacer(minLength: 4)
                    if hype.flash == nil { countdown(now) }
                }
                HStack(spacing: 6) {
                    pills
                    if hype.flash == nil {
                        Text(kickoffText)
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.tText)
                            .lineLimit(1)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Text("\(title) · \(store.t("hype_level")) \(hype.level)")
                        .font(.system(size: 12, weight: .bold)).foregroundColor(.tText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    countdown(now)
                }
                if let n = levelDone {
                    Text(store.t("hype_level_done").replacingOccurrences(of: "{n}", with: "\(n)"))
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.tSuccess)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 6) {
                        ProgressView(value: hype.percent).tint(.tLive)
                        Text("\(Int(hype.percent * 100))%")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundColor(.tMuted)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(now))
    }

    // MARK: Morceaux

    @ViewBuilder
    private func countdown(_ now: Date) -> some View {
        if let ends = hype.endsAt, ends > now {
            HStack(spacing: 3) {
                Image(systemName: "clock.fill").font(.system(size: 9))
                Text(timerInterval: now...ends, countsDown: true)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
            }
            .foregroundColor(.tLive)
            .fixedSize()
        }
    }

    /// Pastilles de Twitch : toutes cochées sauf les `left` dernières ; la
    /// dernière se coche au départ.
    private var pills: some View {
        let count = hype.bigGoal ? 3 : 2
        let filled = hype.flash == .kickoff ? count : max(0, min(count, count - hype.left))
        return HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                pill(filled: i < filled)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: filled)
    }

    private func pill(filled: Bool) -> some View {
        ZStack {
            Circle().stroke(Color.tLive, lineWidth: 1.5)
            if filled {
                Circle().fill(Color.tLive)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .heavy)).foregroundColor(.white)
            }
        }
        .frame(width: 14, height: 14)
        .scaleEffect(filled ? 1 : 0.88)
    }

    // MARK: Textes

    private var kickoffText: String {
        store.t("hype_kickoff").replacingOccurrences(of: "{n}", with: "\(max(1, hype.left))")
    }

    private func endedText(_ e: (level: Int, percent: Int)) -> String {
        store.t("hype_ended")
            .replacingOccurrences(of: "{n}", with: "\(e.level)")
            .replacingOccurrences(of: "{p}", with: "\(e.percent)")
    }

    /// Un seul libellé : titre, soutiens manquants ou niveau, temps restant.
    private func accessibilityText(_ now: Date) -> String {
        if let e = ended { return endedText(e) }
        var parts: [String] = []
        if hype.flash == .departed {
            parts = [store.t("hype_departed"), store.t("hype_departed_sub")]
        } else if showsApproach {
            parts = [title, store.t("hype_incoming")]
            if hype.flash == nil { parts.append(kickoffText) }
        } else {
            parts = ["\(title), \(store.t("hype_level")) \(hype.level)"]
            if let n = levelDone {
                parts.append(store.t("hype_level_done").replacingOccurrences(of: "{n}", with: "\(n)"))
            } else {
                parts.append("\(Int(hype.percent * 100))%")
            }
        }
        if hype.flash != .kickoff, let ends = hype.endsAt, ends > now {
            parts.append(remaining(ends.timeIntervalSince(now)))
        }
        return parts.joined(separator: ", ")
    }

    /// « 2 minutes 30 secondes » dans la langue de l'app.
    private func remaining(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        f.maximumUnitCount = 2
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: store.lang.rawValue)
        f.calendar = calendar
        return f.string(from: seconds.rounded()) ?? "\(Int(seconds)) s"
    }
}

import ActivityKit
import SwiftUI
import WidgetKit

// ═══════════════════════════════════════════════════════════════════════════
//  Extension TwitchUnblockWidgets : la Live Activity du lecteur, sur l'écran
//  verrouillé et dans la Dynamic Island. En plus de la fiche « à l'écoute »
//  d'iOS : badge EN DIRECT, spectateurs, durée du live, progression d'une VOD.
//
//  Une extension ne charge pas d'image distante et n'a pas le code de l'app :
//  tout ce qu'elle affiche arrive dans PlayerActivityAttributes (dossier
//  Shared), déjà mis en forme, et les couleurs sont redéfinies ici.
// ═══════════════════════════════════════════════════════════════════════════

@main
struct TUWidgetBundle: WidgetBundle {
    var body: some Widget {
        PlayerLiveActivity()
    }
}

/// Violet de l'app et rouge du direct.
private let purple  = Color(red: 0.57, green: 0.27, blue: 1)
private let liveRed = Color(red: 0.92, green: 0.10, blue: 0.20)

struct PlayerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PlayerActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let a = context.attributes
            let s = context.state
            // Activité reprise pour une autre chaîne : ce que dit l'état.
            let live = a.isLive(in: s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Badge(attributes: a, state: s)
                        Text(a.channel(in: s)).font(.headline).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TrailingInfo(attributes: a, state: s)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !s.title.isEmpty {
                            Text(s.title).font(.subheadline).lineLimit(2)
                        }
                        Footer(attributes: a, state: s)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                if live {
                    Circle().fill(liveRed).frame(width: 8, height: 8)
                } else {
                    Image(systemName: s.isPlaying ? "play.fill" : "pause.fill")
                        .foregroundColor(purple)
                }
            } compactTrailing: {
                if live {
                    // Sans spectateurs connus : le libellé du direct dans la
                    // langue de l'app (« LIVE » restait en anglais).
                    Text(s.viewers.isEmpty ? a.liveLabel(in: s).uppercased() : s.viewers)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: 56)
                } else {
                    ElapsedText(state: s)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .frame(maxWidth: 56)
                }
            } minimal: {
                if live {
                    Circle().fill(liveRed).frame(width: 8, height: 8)
                } else {
                    Image(systemName: "play.tv.fill").foregroundColor(purple)
                }
            }
        }
    }
}

// MARK: – Écran verrouillé
private struct LockScreenView: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "play.tv.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(purple)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Badge(attributes: attributes, state: state)
                    Text(attributes.channel(in: state)).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    TrailingInfo(attributes: attributes, state: state)
                }
                if !state.title.isEmpty {
                    Text(state.title).font(.subheadline).lineLimit(2)
                }
                Footer(attributes: attributes, state: state)
            }
        }
        .foregroundColor(.white)
        .padding(14)
    }
}

// MARK: – Briques
/// « EN DIRECT » en rouge, ou « VOD » en violet.
private struct Badge: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        let live = attributes.isLive(in: state)
        Text(live ? attributes.liveLabel(in: state).uppercased() : "VOD")
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(live ? liveRed : purple)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// À droite du nom : les spectateurs d'un direct, sinon l'état de la lecture.
private struct TrailingInfo: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if attributes.isLive(in: state), !state.viewers.isEmpty {
            Label(state.viewers, systemImage: "eye.fill")
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
        } else if !state.isPlaying {
            Image(systemName: "pause.fill")
                .font(.caption)
                .foregroundColor(.white.opacity(0.85))
        }
    }
}

/// Direct : catégorie et durée du live (qui défile seule). VOD : barre de
/// progression et temps écoulé / durée.
private struct Footer: View {
    let attributes: PlayerActivityAttributes
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if attributes.isLive(in: state) {
            HStack(spacing: 5) {
                if !state.game.isEmpty {
                    Image(systemName: "gamecontroller.fill").font(.caption2)
                    Text(state.game).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let start = state.startedAt {
                    Text(start, style: .timer)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.75))
        } else if state.duration > 0 {
            VStack(spacing: 4) {
                ProgressBar(state: state)
                HStack {
                    ElapsedText(state: state)
                    Spacer(minLength: 4)
                    // Autre vitesse que 1× : elle est rappelée devant la durée.
                    if state.playbackRate != 1 {
                        Text(speedLabel(state.playbackRate) + " · ")
                    }
                    Text(clock(state.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.75))
            }
        }
    }
}

/// Barre d'une VOD : elle avance seule pendant la lecture (bornes en dates),
/// et reste figée en pause. À 1,5×, elle va au bout en durée / 1,5.
private struct ProgressBar: View {
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, let start = state.startedAt {
            ProgressView(timerInterval: start...start.addingTimeInterval(max(state.duration / state.playbackRate, 1)),
                         countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(purple)
        } else {
            ProgressView(value: min(max(state.position, 0), max(state.duration, 1)),
                         total: max(state.duration, 1))
                .tint(purple)
        }
    }
}

/// Temps écoulé d'une VOD : compteur qui tourne seul pendant la lecture.
/// Un compteur du système suit l'horloge, pas la vidéo : à une autre vitesse
/// que 1×, il affiche le temps réel qui reste avant la fin (« −40:00 »).
private struct ElapsedText: View {
    let state: PlayerActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying, let start = state.startedAt, state.duration > 0 {
            if state.playbackRate != 1 {
                Text("−") + Text(timerInterval: start...start.addingTimeInterval(state.duration / state.playbackRate),
                                 countsDown: true)
            } else {
                Text(timerInterval: start...start.addingTimeInterval(state.duration), countsDown: false)
            }
        } else {
            Text(clock(state.position))
        }
    }
}

/// « 1,5× », dans la langue de l'appareil (l'extension n'a pas celle de l'app).
private func speedLabel(_ rate: Double) -> String {
    rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
}

private func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let t = Int(seconds), h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

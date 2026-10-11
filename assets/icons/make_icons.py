"""Icônes de l'app : l'icône par défaut (ses variantes sombre et teintée) et
les icônes au choix (Réglages → Apparence → Icône de l'app).

Le logo (bouclier façon bulle de chat Twitch, deux « yeux », bouton lecture)
est redessiné ici en formes simples. Le bouton lecture est toujours découpé
dans le bouclier, d'une autre luminosité : en icônes transparentes ou
teintées d'iOS 26, qui ne gardent que la luminosité, il reste lisible.

Pour chaque icône : `<nom>.png` (normale), `<nom>-dark.png` (iOS 18+ en mode
sombre : fond transparent, iOS pose le sien), `<nom>-tinted.png` (gris pur,
pour les icônes teintées et transparentes), un aperçu 180 px pour le réglage
et, pour les icônes au choix, leurs fichiers séparés (loose/). La CI
(build.yml) fait le catalogue de l'icône par défaut et des aperçus ;
buildipa.sh ajoute les icônes au choix à l'app.

    pip install pillow
    python assets/icons/make_icons.py
"""
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter

OUT = os.path.dirname(os.path.abspath(__file__))
SIZE = 1024
SS = 4                      # suréchantillonnage (bords lisses)
S = SIZE * SS


# ── Logo (coordonnées sur 1024, centré) ─────────────────────────────────────
def logo_shapes(scale=1.0):
    """Bouclier, yeux et bouton lecture, en coordonnées suréchantillonnées."""
    w, h = 470 * scale, 560 * scale
    x0, y0 = (SIZE - w) / 2, (SIZE - h) / 2 + 6 * scale

    def p(fx, fy):
        return ((x0 + fx * w) * SS, (y0 + fy * h) * SS)

    shield = [p(0, 0), p(1, 0), p(1, 0.70), p(0.5, 1), p(0, 0.70)]
    eyes = [
        (p(0.70, 0.07), p(0.775, 0.30)),
        (p(0.84, 0.07), p(0.915, 0.24)),
    ]
    play = [p(0.22, 0.30), p(0.80, 0.555), p(0.22, 0.81)]
    return shield, eyes, play


def logo_mask(scale=1.0, cut=True):
    """Masques (L) : bouclier sans les découpes, et découpes (yeux + lecture)."""
    shield, eyes, play = logo_shapes(scale)
    body = Image.new('L', (S, S), 0)
    holes = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(body)
    d.polygon(shield, fill=255)
    # Coins du bouclier légèrement arrondis : tracé épais par-dessus.
    d.line(shield + [shield[0]], fill=255, width=int(18 * SS * scale), joint='curve')
    h = ImageDraw.Draw(holes)
    r = int(19 * SS * scale)
    for (a, b) in eyes:
        h.rounded_rectangle([a, b], radius=r, fill=255)
    h.polygon(play, fill=255)
    h.line(play + [play[0]], fill=255, width=int(14 * SS * scale), joint='curve')
    if cut:
        body = ImageChops.subtract(body, holes)
    return body, holes


def gradient(c1, c2, angle=135):
    """Fond en dégradé (diagonal par défaut), suréchantillonné. Tracé plus
    grand puis recadré : la rotation ne laisse pas de coins vides."""
    big = int(S * 1.45)
    g = Image.linear_gradient('L').resize((big, big)).rotate(angle - 90, resample=Image.BICUBIC)
    off = (big - S) // 2
    g = g.crop((off, off, off + S, off + S))
    a = Image.new('RGB', (S, S), c1)
    b = Image.new('RGB', (S, S), c2)
    return Image.composite(b, a, g)


def finish(img):
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def solid(color):
    return Image.new('RGB', (S, S), color)


def paint(base, mask, fill):
    """Pose `fill` (couleur ou image) sur `base` à travers `mask`."""
    layer = fill if isinstance(fill, Image.Image) else Image.new(base.mode, (S, S), fill)
    base.paste(layer, (0, 0), mask)
    return base


# ── Styles ──────────────────────────────────────────────────────────────────
def icon_purple():
    """Violet Twitch, logo blanc : franc, lisible partout."""
    img = gradient((157, 92, 255), (112, 40, 230))
    body, _ = logo_mask()
    return finish(paint(img, body, (255, 255, 255)))


def icon_night():
    """Nuit : fond presque noir, bouclier violet clair."""
    img = gradient((28, 22, 42), (10, 10, 14))
    body, _ = logo_mask()
    return finish(paint(img, body, (191, 148, 255)))


def icon_light():
    """Clair : fond blanc, bouclier violet."""
    img = gradient((255, 255, 255), (236, 228, 255))
    body, _ = logo_mask()
    return finish(paint(img, body, (145, 70, 255)))


def icon_contrast():
    """Contraste : noir et blanc purs — fait pour les icônes transparentes."""
    img = solid((0, 0, 0))
    body, _ = logo_mask()
    return finish(paint(img, body, (255, 255, 255)))


def icon_neon():
    """Néon : contour lumineux violet → rose sur fond sombre."""
    img = gradient((24, 10, 40), (8, 4, 16))
    shield, eyes, play = logo_shapes()
    shape = Image.new('L', (S, S), 0)
    d = ImageDraw.Draw(shape)
    # Contour du bouclier (refermé par un segment de plus : angles arrondis).
    d.line(shield + [shield[0], shield[1]], fill=255, width=24 * SS, joint='curve')
    for (a, b) in eyes:
        d.rounded_rectangle([a, b], radius=19 * SS, fill=255)
    d.polygon(play, fill=255)
    d.line(play + [play[0]], fill=255, width=14 * SS, joint='curve')
    glow = shape.filter(ImageFilter.GaussianBlur(26 * SS))
    neon = gradient((191, 148, 255), (255, 92, 190), angle=90)
    paint(img, glow.point(lambda v: int(v * 0.9)), neon)
    paint(img, shape, neon)
    return finish(img)


def dark_variant(color):
    """iOS 18+ en sombre : logo seul, fond transparent (iOS pose le sien)."""
    body, _ = logo_mask()
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    img.paste(Image.new('RGBA', (S, S), color + (255,)), (0, 0), body)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def tinted_variant():
    """Teintée et transparente (iOS 18+, 26) : gris pur, logo blanc sur noir."""
    body, _ = logo_mask()
    img = Image.new('L', (S, S), 0)
    img.paste(255, (0, 0), body)
    return img.resize((SIZE, SIZE), Image.LANCZOS)


def save(img, name):
    path = os.path.join(OUT, name)
    img.save(path, optimize=True)
    return path


def preview(img, name):
    os.makedirs(os.path.join(OUT, 'previews'), exist_ok=True)
    img.convert('RGB').resize((180, 180), Image.LANCZOS).save(os.path.join(OUT, 'previews', name), optimize=True)


# Icônes au choix en fichiers séparés (CFBundleIconFiles, comme Feather) :
# déclarées seulement par le catalogue, iOS refusait de les poser sur une
# app installée par Feather (OSStatus -54). buildipa.sh les copie dans l'app.
LOOSE = {'@2x.png': 120, '@3x.png': 180, '@2x~ipad.png': 152}


def loose(img, name):
    os.makedirs(os.path.join(OUT, 'loose'), exist_ok=True)
    for suffix, px in LOOSE.items():
        img.convert('RGB').resize((px, px), Image.LANCZOS).save(
            os.path.join(OUT, 'loose', f'AppIcon-{name}{suffix}'), optimize=True)


if __name__ == '__main__':
    tinted = tinted_variant()
    # Icône par défaut : son dessin reste assets/icon.png ; seules ses
    # variantes sombre et teintée viennent d'ici.
    save(dark_variant((191, 148, 255)), 'AppIcon-dark.png')
    save(tinted, 'AppIcon-tinted.png')
    # Aperçu tel qu'iOS l'affiche : les zones transparentes de l'icône sur noir.
    default = Image.open(os.path.join(OUT, '..', 'icon.png')).convert('RGBA')
    preview(Image.alpha_composite(Image.new('RGBA', default.size, (0, 0, 0, 255)), default), 'Default.png')

    # Icônes au choix : en fichiers séparés, sans versions sombre ni teintée
    # (seul le catalogue les porte) ; leurs dessins jouent déjà le contraste.
    styles = {
        'Purple':   icon_purple,
        'Night':    icon_night,
        'Light':    icon_light,
        'Contrast': icon_contrast,
        'Neon':     icon_neon,
    }
    for name, draw in styles.items():
        img = draw()
        save(img, f'{name}.png')
        preview(img, f'{name}.png')
        loose(img, name)
    print('icônes écrites dans', OUT)

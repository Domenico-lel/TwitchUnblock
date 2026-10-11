"""Icône de l'app Apple TV et images « Top Shelf », dans le catalogue
d'actifs de la cible tvOS (TV/Assets.xcassets).

tvOS veut une icône en calques (effet de relief quand elle a le focus) :
un fond opaque — le dégradé violet de l'icône « Violet » de l'iPhone — et
le logo blanc par-dessus, découpé (yeux, bouton lecture) et ombré. Plus
l'icône de l'App Store (1280×768) et les bannières du rang du haut de
l'écran d'accueil (Top Shelf, normale et large). Le logo vient de
assets/icons/make_icons.py.

    pip install pillow
    python TV/make_tv_icons.py
"""
import importlib.util
import json
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
_spec = importlib.util.spec_from_file_location('make_icons', os.path.join(ROOT, 'assets', 'icons', 'make_icons.py'))
icons = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(icons)

CATALOG = os.path.join(HERE, 'Assets.xcassets')
BRAND = os.path.join(CATALOG, 'App Icon & Top Shelf Image.brandassets')
INFO = {'author': 'xcode', 'version': 1}
PURPLE = ((157, 92, 255), (112, 40, 230))
FONT = 'C:/Windows/Fonts/segoeuib.ttf'   # Segoe UI Bold, pour le nom (Windows)
# Le logo occupe 560/1024 de la hauteur du carré où make_icons le dessine.
LOGO_FRACTION = 560 / 1024

_logo = None


def logo_mask():
    """Bouclier découpé (masque L), en haute définition, gardé une fois fait."""
    global _logo
    if _logo is None:
        _logo, _ = icons.logo_mask()
    return _logo


def gradient(w, h, c1, c2, angle=135):
    """Dégradé w×h (tracé plus grand puis recadré : pas de coins vides)."""
    side = int(max(w, h) * 1.5)
    g = Image.linear_gradient('L').resize((side, side)).rotate(angle - 90, resample=Image.BICUBIC)
    left, top = (side - w) // 2, (side - h) // 2
    g = g.crop((left, top, left + w, top + h))
    return Image.composite(Image.new('RGB', (w, h), c2), Image.new('RGB', (w, h), c1), g)


def logo_on(layer, center, height, color=(255, 255, 255), shadow=0.45):
    """Pose le logo (hauteur `height`, centré sur `center`), ombre douce dessous."""
    w, h = layer.size
    side = int(height / LOGO_FRACTION)
    mask = logo_mask().resize((side, side), Image.LANCZOS)
    x, y = int(center[0] - side / 2), int(center[1] - side / 2)
    if shadow:
        sh = Image.new('L', (w, h), 0)
        sh.paste(mask, (x, y + max(1, int(height * 0.04))))
        sh = sh.filter(ImageFilter.GaussianBlur(max(1, height * 0.05))).point(lambda v: int(v * shadow))
        layer.paste(Image.new('RGBA', (w, h), (25, 0, 60, 255)), (0, 0), sh)
    full = Image.new('L', (w, h), 0)
    full.paste(mask, (x, y))
    layer.paste(Image.new('RGBA', (w, h), color + (255,)), (0, 0), full)
    return layer


def icon_layers(w, h):
    """Fond (opaque) et logo (transparent autour), pour l'icône en relief."""
    back = gradient(w, h, *PURPLE)
    front = logo_on(Image.new('RGBA', (w, h), (0, 0, 0, 0)), (w / 2, h / 2), h * 0.62)
    return back, front


def top_shelf(w, h):
    """Bannière : fond sombre, lueur violette, logo et nom de l'app."""
    img = gradient(w, h, (40, 22, 70), (10, 10, 14), angle=160).convert('RGBA')
    has_font = os.path.exists(FONT)
    font = ImageFont.truetype(FONT, int(h * 0.19)) if has_font else None
    text = 'TwitchUnblock'
    draw = ImageDraw.Draw(img)
    logo_h = h * 0.46
    logo_w = logo_h / LOGO_FRACTION * (470 / 1024)
    gap = h * 0.09
    text_w = draw.textlength(text, font=font) if font else 0
    total = logo_w + (gap + text_w if font else 0)
    left = (w - total) / 2
    center = (left + logo_w / 2, h / 2)

    glow = Image.new('L', (w, h), 0)
    r = h * 0.42
    ImageDraw.Draw(glow).ellipse([center[0] - r, center[1] - r, center[0] + r, center[1] + r], fill=255)
    glow = glow.filter(ImageFilter.GaussianBlur(h * 0.18)).point(lambda v: int(v * 0.55))
    img.paste(Image.new('RGBA', (w, h), (145, 70, 255, 255)), (0, 0), glow)

    logo_on(img, center, logo_h, shadow=0.35)
    if font:
        x0, y0, x1, y1 = draw.textbbox((0, 0), text, font=font)
        draw.text((left + logo_w + gap, h / 2 - (y0 + y1) / 2), text, font=font, fill=(255, 255, 255, 255))
    return img.convert('RGB')


def write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        json.dump(data, f, indent=2)
        f.write('\n')


def imageset(folder, images):
    """images : [(nom de fichier, image, échelle)]."""
    os.makedirs(folder, exist_ok=True)
    for name, img, _ in images:
        img.save(os.path.join(folder, name), optimize=True)
    write_json(os.path.join(folder, 'Contents.json'), {
        'images': [{'filename': name, 'idiom': 'tv', 'scale': scale} for name, _, scale in images],
        'info': INFO,
    })


def imagestack(folder, scales):
    """Icône en calques : scales = [(échelle, largeur, hauteur)]."""
    made = {s: icon_layers(w, h) for s, w, h in scales}
    for i, layer in enumerate(['Front', 'Back']):
        layer_dir = os.path.join(folder, f'{layer}.imagestacklayer')
        write_json(os.path.join(layer_dir, 'Contents.json'), {'info': INFO})
        suffix = {'1x': '', '2x': '@2x'}
        imageset(os.path.join(layer_dir, 'Content.imageset'),
                 [(f'{layer.lower()}{suffix[s]}.png', made[s][1 - i], s) for s, _, _ in scales])
    write_json(os.path.join(folder, 'Contents.json'), {
        'info': INFO,
        'layers': [{'filename': 'Front.imagestacklayer'}, {'filename': 'Back.imagestacklayer'}],
    })


if __name__ == '__main__':
    write_json(os.path.join(CATALOG, 'Contents.json'), {'info': INFO})
    imagestack(os.path.join(BRAND, 'App Icon.imagestack'), [('1x', 400, 240), ('2x', 800, 480)])
    imagestack(os.path.join(BRAND, 'App Icon - App Store.imagestack'), [('1x', 1280, 768)])
    imageset(os.path.join(BRAND, 'Top Shelf Image.imageset'),
             [('top.png', top_shelf(1920, 720), '1x'), ('top@2x.png', top_shelf(3840, 1440), '2x')])
    imageset(os.path.join(BRAND, 'Top Shelf Image Wide.imageset'),
             [('top-wide.png', top_shelf(2320, 720), '1x'), ('top-wide@2x.png', top_shelf(4640, 1440), '2x')])
    write_json(os.path.join(BRAND, 'Contents.json'), {
        'assets': [
            {'filename': 'App Icon - App Store.imagestack', 'idiom': 'tv', 'role': 'primary-app-icon', 'size': '1280x768'},
            {'filename': 'App Icon.imagestack', 'idiom': 'tv', 'role': 'primary-app-icon', 'size': '400x240'},
            {'filename': 'Top Shelf Image Wide.imageset', 'idiom': 'tv', 'role': 'top-shelf-image-wide', 'size': '2320x720'},
            {'filename': 'Top Shelf Image.imageset', 'idiom': 'tv', 'role': 'top-shelf-image', 'size': '1920x720'},
        ],
        'info': INFO,
    })
    print('catalogue écrit dans', CATALOG)

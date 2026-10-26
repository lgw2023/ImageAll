"""Use a glyph-local soft shadow instead of the PhotoStory caption panel."""
import json
from pathlib import Path


def default_text_shadow():
    style = json.loads(Path(__file__).with_name('caption-style-defaults.json').read_text())
    if (style['version'] != 1 or style['background'] != 'none' or style['backdropBlur']
            or style['offsetX'] != 0 or style['offsetY'] != 0):
        raise RuntimeError('Review the approved caption appearance before changing defaults')
    rgb = ','.join(str(value) for value in style['shadowRGB'])
    edge = style['referenceShortEdge']
    return ', '.join(
        f"0 0 ${{{layer['blur']} * shortEdge / {edge}}}px rgba({rgb},{layer['opacity']})"
        for layer in style['shadowLayers']
    )


def apply(engine):
    path = engine / 'remotion-composer/src/PhotoStory.tsx'
    source = path.read_text()
    before = '''          borderRadius: Math.round(shortEdge * 0.018),
          background: "rgba(7, 12, 20, 0.70)",
          boxShadow: "0 12px 44px rgba(0,0,0,0.28)",'''
    after = "          textShadow: `" + default_text_shadow() + "`,"
    if after not in source:
        if before not in source:
            raise RuntimeError('Pinned PhotoStory caption panel changed; review shadow patch')
        source = source.replace(before, after)
    source = source.replace('          backdropFilter: "blur(8px)",\n', '')
    path.write_text(source)

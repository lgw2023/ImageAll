"""Pinned PhotoStory typography extension, shared by preview and final render."""
import json
import hashlib
from pathlib import Path

from integration_contract import CONTRACT
STORY_SCHEMA_SHA256 = CONTRACT['legacyStorySchemaSHA256']
UPSTREAM_SCHEMA_SHA256 = CONTRACT['upstreamStorySchemaSHA256']


def synchronize_story_schema_lock(engine: Path):
    """Pin the reviewed extension, never bless arbitrary schema modifications."""
    directory = engine / 'schemas/integrations'
    data = (directory / 'story_render_package_v0_1.schema.json').read_bytes()
    if hashlib.sha256(data).hexdigest() != STORY_SCHEMA_SHA256:
        raise RuntimeError('Story typography schema changed; review the schema and Swift exporter digest')
    path = directory / 'story_render_package_v0_1.lock.json'
    lock = json.loads(path.read_text())
    if lock.get('sha256') not in (UPSTREAM_SCHEMA_SHA256, STORY_SCHEMA_SHA256):
        raise RuntimeError('Unknown upstream story schema lock; review before packaging')
    if lock['sha256'] == UPSTREAM_SCHEMA_SHA256:
        upstream = dict(lock)
        lock = {key: value for key, value in lock.items() if key not in ('introducedInCommit', 'gitBlobSHA1')}
        lock['upstreamLock'] = upstream
    lock.update(sha256=STORY_SCHEMA_SHA256, byteLength=len(data), lineCount=data.count(b'\n'),
                lineEnding='LF', finalNewline=data.endswith(b'\n'), utf8BOM=data.startswith(b'\xef\xbb\xbf'),
                integration='ImageAll ADR-100 typography extension')
    path.write_text(json.dumps(lock, ensure_ascii=False, indent=2) + '\n')


def apply(engine: Path):
    fields = {
        'titleFontSize': {'type': 'number', 'minimum': 24, 'maximum': 120},
        'captionFontSize': {'type': 'number', 'minimum': 16, 'maximum': 80},
        'fontWeight': {'type': 'integer', 'enum': [400, 700]},
    }
    for relative in ['schemas/integrations/story_render_package_v0_1.schema.json', 'schemas/artifacts/edit_decisions.schema.json']:
        path = engine / relative
        data = json.loads(path.read_text())
        def visit(node):
            if isinstance(node, dict):
                props = node.get('properties', {})
                if 'fontFamily' in props and 'safeMarginRatio' in props:
                    props.update(fields)
                for child in node.values(): visit(child)
            elif isinstance(node, list):
                for child in node: visit(child)
        visit(data)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    synchronize_story_schema_lock(engine)
    path = engine / 'remotion-composer/src/PhotoStory.tsx'
    source = path.read_text()
    replacements = {
        '  fontFamily?: string;': '  fontFamily?: string;\n  titleFontSize?: number;\n  captionFontSize?: number;\n  fontWeight?: number;',
        'fontSize: titleFontSize(text, shortEdge, shot.kind),': 'fontSize: template.titleFontSize ? template.titleFontSize * shortEdge / 1080 * (shot.kind === "title" ? 1 : 0.8) : titleFontSize(text, shortEdge, shot.kind),',
        'fontWeight: 650,': 'fontWeight: template.fontWeight ?? 650,',
        'fontSize: Math.round(clamp(shortEdge * 0.029, 26, 44)),': 'fontSize: template.captionFontSize ? template.captionFontSize * shortEdge / 1080 : Math.round(clamp(shortEdge * 0.029, 26, 44)),\n              fontWeight: template.fontWeight ?? 400,',
        '`${story.template.fontFamily ?? "Hiragino Sans GB"}, "Heiti SC", sans-serif`': '`${JSON.stringify(story.template.fontFamily ?? "PingFang SC")}, "PingFang SC", sans-serif`',
    }
    for before, after in replacements.items():
        if after in source: continue
        if before not in source: raise RuntimeError('Pinned PhotoStory changed: ' + before)
        source = source.replace(before, after)
    path.write_text(source)
    # The poem template uses its own text component; carry the same explicit style.
    path = engine / 'lib/story_style_templates.py'
    source = path.read_text()
    before = "    return dict(shots=shots,poems=poems,totalFrames=cursor,fontSize=req['style']['template']['fontSize'],bottomPercent=req['style']['template']['bottomPercent'])"
    after = "    style = package.data['export']['template']\n    return dict(shots=shots,poems=poems,totalFrames=cursor,fontSize=style.get('captionFontSize', req['style']['template']['fontSize']),fontFamily=style.get('fontFamily', 'SailimuBrush'),fontWeight=style.get('fontWeight', 400),bottomPercent=req['style']['template']['bottomPercent'])"
    if after not in source:
        if before not in source: raise RuntimeError('Pinned poem props changed')
        source = source.replace(before, after)
    source = source.replace("    if any(ord(c) not in cmap", "    if not package.data['export']['template'].get('fontFamily') and any(ord(c) not in cmap")
    path.write_text(source)
    path = engine / 'templates/photo-styles/poem.tsx'
    source = path.read_text()
    for before, after in {
        'fontSize:number;bottomPercent:number': 'fontSize:number;bottomPercent:number;fontFamily?:string;fontWeight?:number',
        '({poem:p,shots,fontSize,bottomPercent})': '({poem:p,shots,fontSize,bottomPercent,fontFamily="SailimuBrush",fontWeight=400})',
        "fontFamily:'SailimuBrush',fontWeight:400": 'fontFamily:JSON.stringify(fontFamily),fontWeight',
        '({shots,poems=[],fontSize=46,bottomPercent=6})': '({shots,poems=[],fontSize=46,bottomPercent=6,fontFamily="SailimuBrush",fontWeight=400})',
        'fontSize={fontSize} bottomPercent={bottomPercent}': 'fontSize={fontSize} bottomPercent={bottomPercent} fontFamily={fontFamily} fontWeight={fontWeight}',
    }.items():
        if after not in source:
            if before not in source: raise RuntimeError('Pinned poem component changed')
            source = source.replace(before, after)
    path.write_text(source)

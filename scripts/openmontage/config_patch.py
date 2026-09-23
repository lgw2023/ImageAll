"""Apply the small integration patch to the pinned runtime source."""
from pathlib import Path

def apply(engine: Path):
    import typography_patch
    typography_patch.apply(engine)
    module = engine / 'lib/config_model.py'
    source = module.read_text()
    original = 'config_path = Path(__file__).resolve().parent.parent / "config.yaml"'
    replacement = 'import os\n            config_path = Path(os.environ["OPENMONTAGE_CONFIG_PATH"]) if os.environ.get("OPENMONTAGE_CONFIG_PATH") else Path(__file__).resolve().parent.parent / "config.yaml"'
    if replacement not in source:
        if original not in source: raise RuntimeError('Pinned configuration loader changed; review integration patch')
        module.write_text(source.replace(original, replacement))
    overrides = Path(__file__).parent / 'overrides'
    for name, target in [('model_connection.py', 'lib/model_connection.py'),
                         ('private_photo_vision.py', 'lib/private_photo_vision.py'),
                         ('private_photo_vision_tool.py', 'tools/analysis/private_photo_vision.py')]:
        (engine / target).write_bytes((overrides / name).read_bytes())
    (engine / 'lib/story_auto_creative.py').write_bytes((overrides / 'story_auto_creative.py').read_bytes())
    worker = engine / 'lib/story_task_executor.py'
    source = worker.read_text()
    if 'from lib.story_auto_creative import CreativeWorker' not in source:
        replacements = {
            '    templates = TemplateWorker(executor.task_root)': '    templates = TemplateWorker(executor.task_root)\n    from lib.story_auto_creative import CreativeWorker\n    creative = CreativeWorker(executor.task_root)',
            'accept_new=drain_mode is None and templates.process is None,': 'accept_new=drain_mode is None and templates.process is None and creative.process is None,',
            'template_active = templates.tick(accept=drain_mode is None and active is None)': 'template_active = templates.tick(accept=drain_mode is None and active is None and creative.process is None)\n            creative_active = creative.tick(accept=drain_mode is None and active is None and not template_active, cancel=drain_mode == "cancel-current")',
            'drain_mode and active is None and not template_active': 'drain_mode and active is None and not template_active and not creative_active',
        }
        for before, after in replacements.items():
            if before not in source: raise RuntimeError('Pinned executor changed; review creative integration')
            source = source.replace(before, after)
        worker.write_text(source)

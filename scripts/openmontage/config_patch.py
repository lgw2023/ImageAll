"""Apply the small integration patch to the pinned runtime source."""
from pathlib import Path

def apply(engine: Path):
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

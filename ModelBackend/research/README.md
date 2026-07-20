# Model research inputs

This directory contains explicit, immutable inputs and reproducible evidence for model admission work. It is not an App resource directory.

## Places365 ResNet18

- Official-download evidence: `inputs/places365/20260720T020727Z/`
- Repository evidence manifest: `manifests/places365-resnet18-official-weight-20260720.json`
- Public-validation blocker manifest: `manifests/places365-public-validation-20260720.json`
- The original `.pth.tar` is intentionally ignored by Git and must never be added to the Xcode project or an App bundle.
- The input tree was moved from `/Volumes/SSD1/places365-evidence/` without downloading again and made read-only.
- Loading is prohibited while the candidate remains `research`. If the license and public-data gates later close, use only an isolated temporary directory and `torch.load(..., weights_only=True)`; never fall back to unrestricted pickle loading.
- The public-validation blocker manifest intentionally contains no dataset identity or items. It records that no fixed, license-reviewed public validation dataset is approved; it must not be presented as evaluation evidence.

Python/uv tooling under `ModelBackend` is limited to conversion, offline evaluation, and development validation. Production inference runs in the App process through Swift/Core ML.

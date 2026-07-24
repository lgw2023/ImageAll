# Model research inputs

This directory contains explicit, immutable inputs and reproducible evidence for model admission work. It is not an App resource directory.

## Places365 ResNet18

- Official-download evidence: `inputs/places365/20260720T020727Z/`
- Repository evidence manifest: `manifests/places365-resnet18-official-weight-20260720.json`
- Public-validation blocker manifest: `manifests/places365-public-validation-20260720.json`
- The original `.pth.tar` is intentionally ignored by Git and must never be added to the Xcode project or an App bundle.
- The input tree was moved from `/Volumes/SSD1/places365-evidence/` without downloading again and made read-only.
- **Product disposition (2026-07-24):** the project owner formally rejected Places365 ResNet18 as a production standard pack candidate. Admission reports remain `research`; do not reopen license/data gates, load the checkpoint, convert Core ML, or ship this candidate. Keep the archival evidence only.
- The public-validation blocker manifest records that Places365 validation is **permanently inapplicable** after that rejection. It must not be presented as evaluation evidence or filled with Places2/Places365 images.
- A future production scene pack requires a **new** candidate with versioned, redistribution-clear licenses and a separately reviewed public validation set.

Python/uv tooling under `ModelBackend` is limited to conversion, offline evaluation, and development validation. Production inference runs in the App process through Swift/Core ML.

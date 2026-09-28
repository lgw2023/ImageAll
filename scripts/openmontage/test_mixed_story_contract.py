import copy
import json
from pathlib import Path
import unittest
from jsonschema import Draft202012Validator, ValidationError
from mixed_story_contract import SCHEMA, validate_document


def fixture():
    return {
        'schemaVersion': '0.2', 'projectID': 'mixed', 'projectRevision': 'revision-1',
        'export': {'width': 1920, 'height': 1080, 'fps': 30, 'totalFrames': 60,
                   'background': {'color': '#000000', 'mode': 'solid'},
                   'template': {'name': 'family-photo-story', 'version': '0.1'}},
        'assets': [
            {'assetID': 'photo', 'relativePath': 'assets/photo.jpg', 'mediaType': 'image/jpeg',
             'sourceContentVersion': 'catalog-revision-1', 'renderFileSHA256': 'a'*64},
            {'assetID': 'video', 'relativePath': 'assets/video.mp4', 'mediaType': 'video/mp4',
             'sourceContentVersion': 'catalog-revision-2', 'renderFileSHA256': 'b'*64,
             'video': {'durationMs': 2000, 'hasAudio': True}}],
        'chapters': [{'chapterID': 'chapter', 'sequenceIndex': 0, 'title': 'Mixed',
                      'trace': {'sourceChapterID': 'chapter'}, 'shots': [
            {'shotID': 'p', 'sequenceIndex': 0, 'kind': 'photo', 'assetID': 'photo',
             'startFrame': 0, 'durationFrames': 30, 'fit': {'mode': 'contain', 'allowCrop': False},
             'motion': {'type': 'static'}, 'transitionIn': {'type': 'cut', 'durationFrames': 0},
             'trace': {'originalShotID': 'p'}},
            {'shotID': 'v', 'sequenceIndex': 1, 'kind': 'video', 'assetID': 'video',
             'startFrame': 30, 'durationFrames': 30, 'fit': {'mode': 'contain', 'allowCrop': False},
             'videoClip': {'inFrame': 15, 'outFrame': 45, 'originalAudioGain': 0.5},
             'transitionIn': {'type': 'cut', 'durationFrames': 0}, 'trace': {'originalShotID': 'v'}}]}],
        'trace': {'upstreamPolicyVersion': 'synthetic'}}


class MixedStoryContractTests(unittest.TestCase):
    def test_mixed_document_validates_without_rewriting(self):
        Draft202012Validator.check_schema(SCHEMA)
        self.assertTrue(SCHEMA["$id"].endswith("/0.2"))
        document = fixture(); before = copy.deepcopy(document)
        self.assertIs(validate_document(document), document)
        self.assertEqual(document, before)
        document['assets'][1]['video']['hasAudio'] = False
        document['chapters'][0]['shots'][1]['videoClip']['originalAudioGain'] = 0
        validate_document(document)

    def test_invalid_ranges_identities_and_audio_are_rejected(self):
        edits = [
            lambda d: d['chapters'][0]['shots'][1]['videoClip'].update(inFrame=45),
            lambda d: d['chapters'][0]['shots'][1]['videoClip'].update(outFrame=90),
            lambda d: d['chapters'][0]['shots'][1]['videoClip'].update(originalAudioGain=1.1),
            lambda d: d['chapters'][0]['shots'][1]['videoClip'].update(originalAudioGain=float('nan')),
            lambda d: d['chapters'][0]['shots'][1].update(assetID='photo'),
            lambda d: d['chapters'][0]['shots'][1].update(durationFrames=29),
            lambda d: d['chapters'][0]['shots'][1].update(startFrame=20),
            lambda d: d['chapters'][0]['shots'][1].update(motion={'type': 'static'}),
            lambda d: d['assets'].append(copy.deepcopy(d['assets'][1])),
            lambda d: d['assets'][1].update(relativePath='../outside.mp4'),
            lambda d: d['assets'][1].pop('video'),
            lambda d: d['export'].update(totalFrames=61),
        ]
        for edit in edits:
            with self.subTest(edit=edits.index(edit)):
                document = fixture(); edit(document)
                with self.assertRaises((ValueError, ValidationError)):
                    validate_document(document)

    def test_legacy_schema_rejects_mixed_document(self):
        root = Path(__file__).resolve().parents[2]
        schema = json.loads((root/'Vendor/OpenMontage/Runtime/engine/schemas/integrations/story_render_package_v0_1.schema.json').read_text())
        with self.assertRaises(ValidationError):
            Draft202012Validator(schema).validate(fixture())
        photo_only = fixture()
        photo_only['schemaVersion'] = '0.1'
        photo_only['assets'] = photo_only['assets'][:1]
        photo_only['chapters'][0]['shots'] = photo_only['chapters'][0]['shots'][:1]
        photo_only['export']['totalFrames'] = 30
        Draft202012Validator(schema).validate(photo_only)
        photo_only['schemaVersion'] = '0.2'
        validate_document(photo_only)
        disguised = fixture(); disguised['schemaVersion'] = '0.1'
        with self.assertRaises(ValidationError):
            Draft202012Validator(schema).validate(disguised)


if __name__ == '__main__':
    unittest.main()

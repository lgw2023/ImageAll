"""Render and independently verify synthetic photo/video output, without a Photos host."""
import sys, json, subprocess
from pathlib import Path
from test_mixed_story_assets import MixedStoryAssetTests
from mixed_story_adapter import prepared_story
import argparse
from mixed_story_renderer_patch import apply
parser = argparse.ArgumentParser(description='Synthetic mixed-story render acceptance; writable composer copy required')
parser.add_argument('composer', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--browser', default='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
args = parser.parse_args()
composer = args.composer.resolve()
root = args.output.resolve()
root.mkdir(parents=True, exist_ok=True)
apply(composer)
(composer/'src/MixedStorySmoke.tsx').write_text('''import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {PhotoStory, calculatePhotoStoryMetadata, defaultPhotoStoryProps} from './PhotoStory';
const Root: React.FC = () => <Composition id="MixedStory" component={PhotoStory}
  durationInFrames={60} width={1920} height={1080} fps={30}
  defaultProps={defaultPhotoStoryProps} calculateMetadata={calculatePhotoStoryMetadata} />;
registerRoot(Root);
''')
public = composer/'public'
public.mkdir(exist_ok=True)
MixedStoryAssetTests.setUpClass()
try:
    fixture = MixedStoryAssetTests
    document = fixture.document
    document['export'].update(width=320, height=240)
    document['export']['template']['safeMarginRatio'] = 0.03
    with prepared_story(document, fixture.root, work_parent=public) as (frozen, props, facts):
        for shot in props['story_render']['shots']:
            if 'src' in shot:
                shot['src'] = str(Path(shot['src']).relative_to(public))
        (root/'props.json').write_text(json.dumps(props, indent=2))
        (root/'facts.json').write_text(json.dumps(facts, indent=2))
        subprocess.run(['node', 'node_modules/@remotion/cli/remotion-cli.js', 'render', 'src/MixedStorySmoke.tsx',
                        'MixedStory', str(root/'mixed.mp4'), '--props='+str(root/'props.json'),
                        '--browser-executable='+args.browser,
                        '--concurrency=2', '--log=error'], cwd=composer, check=True)
finally:
    MixedStoryAssetTests.tearDownClass()

import array, hashlib, json, math, subprocess
from pathlib import Path
video = root/'mixed.mp4'
def run(args):
    return subprocess.check_output(args)
probe = json.loads(run(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(video)]))
assert abs(float(probe['format']['duration'])-2) < .1
assert next(s for s in probe['streams'] if s['codec_type']=='video')['nb_frames'] == '60'
assert any(s['codec_type']=='audio' for s in probe['streams'])
def frame(time):
    return run(['ffmpeg','-v','error','-ss',str(time),'-i',str(video),'-frames:v','1','-vf','scale=64:48','-f','rawvideo','-pix_fmt','rgb24','-'])
a,b=frame(1.2),frame(1.7)
assert len(a)==len(b)==64*48*3
motion=sum(abs(x-y) for x,y in zip(a,b))/len(a)
assert motion>2, motion
def rms(time,duration):
    data=run(['ffmpeg','-v','error','-ss',str(time),'-i',str(video),'-t',str(duration),'-vn','-ar','44100','-f','f32le','-'])
    samples=array.array('f');samples.frombytes(data)
    return math.sqrt(sum(v*v for v in samples)/len(samples))
silence=rms(.1,.7);sound=rms(1.1,.7)
assert silence<.0001, silence
assert .035<sound<.053, sound
result={'durationSeconds':float(probe['format']['duration']), 'meanFrameDifference':motion,
        'photoSegmentRMS':silence,'videoHalfGainRMS':sound,
        'sha256':hashlib.sha256(video.read_bytes()).hexdigest(), 'streams':[(s['codec_type'],s['codec_name']) for s in probe['streams']]}
(root/'verification.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
run(['ffmpeg','-v','error','-y','-ss','1.5','-i',str(video),'-frames:v','1',str(root/'video-frame.png')])

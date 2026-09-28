"""Verify MOV rotation metadata survives the mixed-package render path."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from PIL import Image
from mixed_story_adapter import prepared_story
from mixed_story_renderer_patch import apply
from test_mixed_story_contract import fixture

parser = argparse.ArgumentParser()
parser.add_argument('composer', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
composer = args.composer.resolve()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
apply(composer)

def run(arguments):
    return subprocess.check_output(arguments, stderr=subprocess.PIPE)

with tempfile.TemporaryDirectory(prefix='ImageAllOrientation-') as temporary:
    root = Path(temporary)
    (root/'assets').mkdir()
    Image.new('RGB', (128, 64), 'green').save(root/'assets/photo.jpg')
    run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
         'color=blue:size=128x64:rate=30:duration=2,drawbox=x=0:y=0:w=64:h=64:color=red:t=fill',
         '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(root/'encoded.mp4')])
    run(['ffmpeg', '-v', 'error', '-display_rotation:v:0', '90', '-i', str(root/'encoded.mp4'), '-c', 'copy', str(root/'assets/rotated.mov')])
    probe = json.loads(run(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(root/'assets/rotated.mov')]))
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    assert any(abs(s.get('rotation', 0)) == 90 for s in video.get('side_data_list', [])), probe
    document = fixture()
    document['export'].update(width=320, height=240)
    document['assets'][1].update(relativePath='assets/rotated.mov', mediaType='video/quicktime',
                                video={'durationMs': 2000, 'hasAudio': False})
    document['chapters'][0]['shots'][1]['videoClip']['originalAudioGain'] = 0
    for asset in document['assets']:
        asset['renderFileSHA256'] = hashlib.sha256((root/asset['relativePath']).read_bytes()).hexdigest()
    (output/'source.mov').write_bytes((root/'assets/rotated.mov').read_bytes())
    public = composer/'public'
    public.mkdir(exist_ok=True)
    (composer/'src/OrientationAcceptance.tsx').write_text('''import React from 'react';
import {Composition, registerRoot} from 'remotion';
import {PhotoStory, calculatePhotoStoryMetadata, defaultPhotoStoryProps} from './PhotoStory';
const Root: React.FC = () => <Composition id="Orientation" component={PhotoStory} durationInFrames={60}
 width={320} height={240} fps={30} defaultProps={defaultPhotoStoryProps} calculateMetadata={calculatePhotoStoryMetadata}/>;
registerRoot(Root);
''')
    with prepared_story(document, root, work_parent=public) as (_, props, facts):
        for shot in props['story_render']['shots']:
            if 'src' in shot:
                shot['src'] = str(Path(shot['src']).relative_to(public))
        (output/'props.json').write_text(json.dumps(props, indent=2))
        subprocess.run(['node', 'node_modules/@remotion/cli/remotion-cli.js', 'render', 'src/OrientationAcceptance.tsx',
                        'Orientation', str(output/'orientation.mp4'), '--props='+str(output/'props.json'),
                        '--browser-executable=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
                        '--concurrency=2', '--log=error'], cwd=composer, check=True)
    run(['ffmpeg', '-v', 'error', '-i', str(output/'orientation.mp4'), '-f', 'null', '-'])
    run(['ffmpeg', '-v', 'error', '-y', '-ss', '1.5', '-i', str(output/'orientation.mp4'), '-frames:v', '1', str(output/'frame.png')])
    with Image.open(output/'frame.png') as image:
        pixels = image.convert('RGB')
        red, blue = [], []
        for y in range(image.height):
            for x in range(image.width):
                r, g, b = pixels.getpixel((x,y))
                if r > 160 and g < 70 and b < 70: red.append((x,y))
                if b > 160 and g < 70 and r < 70: blue.append((x,y))
        assert len(red) > 1000 and len(blue) > 1000
        centers = [[sum(p[i] for p in region)/len(region) for i in (0,1)] for region in (red,blue)]
        assert abs(centers[0][0]-centers[1][0]) < 5, centers
        # Counter-clockwise 90 degrees maps the encoded left (red) half below blue.
        assert centers[0][1]-centers[1][1] > 50, centers
    result = json.loads(run(['ffprobe','-v','error','-show_streams','-of','json',str(output/'orientation.mp4')]))
    track = next(s for s in result['streams'] if s['codec_type']=='video')
    assert int(track['nb_frames']) == 60 and abs(float(track['duration'])-2)<0.001
    evidence = {'sourceEncodedSize': [video['width'],video['height']], 'rotation': 90, 'renderColorCenters': centers,
                'frames': 60, 'durationSeconds': 2, 'outputSHA256': hashlib.sha256((output/'orientation.mp4').read_bytes()).hexdigest()}
    (output/'verification.json').write_text(json.dumps(evidence,indent=2))
    print(json.dumps(evidence,indent=2))

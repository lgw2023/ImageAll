"""Apply mixed-video support to a writable Remotion composer copy only."""
from pathlib import Path

VIDEO_PLATE = '''const VideoPlate: React.FC<{
  shot: PhotoStoryShot;
  template: StoryTemplate;
  background: StoryBackground;
}> = ({shot, template, background}) => {
  const {width, height} = useVideoConfig();
  if (!shot.src || !shot.fit || !shot.videoClip) {
    throw new Error("Video shot is missing its frozen source or clip range");
  }
  const clip = shot.videoClip;
  if (!Number.isInteger(clip.inFrame) || !Number.isInteger(clip.outFrame) ||
      clip.inFrame < 0 || clip.outFrame - clip.inFrame !== shot.durationFrames ||
      !Number.isFinite(clip.originalAudioGain) || clip.originalAudioGain < 0 || clip.originalAudioGain > 1) {
    throw new Error("Invalid frozen video clip");
  }
  const safe = shot.fit.safeArea;
  const objectPosition = safe
    ? `${clamp((safe.x + safe.width / 2) * 100, 0, 100)}% ${clamp((safe.y + safe.height / 2) * 100, 0, 100)}%`
    : "50% 50%";
  const margin = Math.round(Math.min(width, height) * (template.safeMarginRatio ?? 0.07) * 0.45);
  const source = resolveAsset(shot.src);
  return (
    <AbsoluteFill style={{background: background.color, overflow: "hidden"}}>
      {background.mode === "blurred-photo" ? (
        <>
          <Video src={source} trimBefore={clip.inFrame} trimAfter={clip.outFrame} muted
            style={{position: "absolute", inset: -24, width: "calc(100% + 48px)",
              height: "calc(100% + 48px)", objectFit: "cover", objectPosition,
              filter: `blur(${background.blurPixels ?? 24}px) saturate(0.9)`}} />
          <AbsoluteFill style={{background: `rgba(0,0,0,${background.dimOpacity ?? 0.38})`}} />
        </>
      ) : null}
      <AbsoluteFill style={{padding: margin, boxSizing: "border-box"}}>
        <Video src={source} trimBefore={clip.inFrame} trimAfter={clip.outFrame}
          volume={clip.originalAudioGain} muted={clip.originalAudioGain === 0}
          style={{width: "100%", height: "100%", objectFit: shot.fit.mode, objectPosition}} />
      </AbsoluteFill>
      {shot.caption ? <Caption caption={shot.caption} template={template} /> : null}
    </AbsoluteFill>
  );
};

'''


def apply(composer):
    composer = Path(composer).resolve()
    seed = Path(__file__).resolve().parents[2] / 'Vendor/OpenMontage/Runtime'
    if composer == seed or seed in composer.parents:
        raise ValueError('Runtime seed is read-only')
    target = composer / 'src/PhotoStory.tsx'
    source = target.read_text()
    if 'const VideoPlate:' in source:
        return
    edits = [
        ('import {Audio} from "@remotion/media";', 'import {Audio, Video} from "@remotion/media";'),
        ('kind: "title" | "chapter-title" | "photo" | "outro";', 'kind: "title" | "chapter-title" | "photo" | "video" | "outro";'),
        ('  motion?: StoryMotion;', '  motion?: StoryMotion;\n  videoClip?: {inFrame: number; outFrame: number; originalAudioGain: number};'),
        ('  schemaVersion: "0.1";', '  schemaVersion: "0.1" | "0.2";'),
        ('const StoryShot:', VIDEO_PLATE + 'const StoryShot:'),
        ('<PhotoPlate shot={shot} template={template} background={background} />\n      ) : (',
         '<PhotoPlate shot={shot} template={template} background={background} />\n      ) : shot.kind === "video" ? (\n        <VideoPlate shot={shot} template={template} background={background} />\n      ) : ('),
    ]
    for old, new in edits:
        if source.count(old) != 1:
            raise ValueError(f'Renderer patch anchor drift: {old[:60]}')
        source = source.replace(old, new)
    target.write_text(source)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('composer')
    apply(parser.parse_args().composer)

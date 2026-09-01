import { useCallback, useEffect, useRef, useState } from 'react';

import { analyzeAssetLocalSuggestions } from '@/api/assets';
import type {
  AssetLocalSuggestion,
  AssetLocalSuggestionState,
  AssetLocalSuggestionTrack,
} from '@/api/contracts/asset';
import { errorMessage } from '@/api/errors';

type LocalSuggestionViewState = {
  status: 'ready' | 'loading' | AssetLocalSuggestionState;
  track: AssetLocalSuggestionTrack;
  suggestions: AssetLocalSuggestion[];
  message: string;
};

const READY_STATE: LocalSuggestionViewState = {
  status: 'ready',
  track: 'standard',
  suggestions: [],
  message: '选择一个模型，只分析当前照片。',
};

function stateMessage(state: AssetLocalSuggestionState): string {
  return {
    results: '分析完成。',
    previewUnavailable: '本地预览尚不可用，请先从 iCloud 获取当前照片预览。',
    personalUnavailable: '当前目录还没有可用于这些标签的个人模型。',
    serviceUnavailable: '本地模型服务当前不可用；照片和已有标签不受影响。',
    failed: '结果未通过安全校验，已忽略本次分析。',
  }[state];
}

export function useLocalSuggestions(assetID: string) {
  const [state, setState] = useState<LocalSuggestionViewState>(READY_STATE);
  const generationRef = useRef(0);
  const controllerRef = useRef<AbortController | null>(null);

  useEffect(() => {
    return () => {
      generationRef.current += 1;
      controllerRef.current?.abort();
      controllerRef.current = null;
    };
  }, [assetID]);

  const run = useCallback(
    async (track: AssetLocalSuggestionTrack) => {
      const generation = ++generationRef.current;
      controllerRef.current?.abort();
      const controller = new AbortController();
      controllerRef.current = controller;
      setState({
        status: 'loading',
        track,
        suggestions: [],
        message: `正在运行${track === 'personal' ? '个人标签' : '标准场景'}模型…`,
      });
      try {
        const response = await analyzeAssetLocalSuggestions(
          assetID,
          crypto.randomUUID(),
          track,
          controller.signal,
        );
        if (
          generation !== generationRef.current ||
          response.assetID !== assetID ||
          response.track !== track
        )
          return;
        setState({
          status: response.state,
          track,
          suggestions: response.state === 'results' ? response.suggestions : [],
          message:
            response.state === 'results' && response.suggestions.length === 0
              ? '当前模型没有给出建议。'
              : stateMessage(response.state),
        });
      } catch (error) {
        if (controller.signal.aborted || generation !== generationRef.current) return;
        setState({
          status: 'failed',
          track,
          suggestions: [],
          message: errorMessage(error),
        });
      } finally {
        if (controllerRef.current === controller) controllerRef.current = null;
      }
    },
    [assetID],
  );

  const dismiss = useCallback((suggestionID: string) => {
    setState((current) => ({
      ...current,
      suggestions: current.suggestions.filter((suggestion) => suggestion.id !== suggestionID),
      message: current.suggestions.length === 1 ? '当前模型建议已处理完。' : current.message,
    }));
  }, []);

  return { state, run, dismiss };
}

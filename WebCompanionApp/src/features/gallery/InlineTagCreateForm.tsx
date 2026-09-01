import { useEffect, useRef, useState, type SyntheticEvent } from 'react';

import { Plus } from 'lucide-react';

import { errorMessage } from '@/api/errors';

type InlineTagCreateFormProps = {
  assetIDs: string[];
  disabled: boolean;
  inputLabel: string;
  onCreate: (name: string, assetIDs: string[], operationID: string) => Promise<void>;
};

export function InlineTagCreateForm({
  assetIDs,
  disabled,
  inputLabel,
  onCreate,
}: InlineTagCreateFormProps) {
  const inputRef = useRef<HTMLInputElement>(null);
  const operationRef = useRef<{ name: string; operationID: string } | null>(null);
  const restoreFocusRef = useRef(false);
  const [name, setName] = useState('');
  const [failure, setFailure] = useState('');
  const [submitting, setSubmitting] = useState(false);

  useEffect(() => {
    if (disabled || submitting || !restoreFocusRef.current) return;
    restoreFocusRef.current = false;
    inputRef.current?.focus({ preventScroll: true });
  }, [disabled, submitting]);

  async function submit(event: SyntheticEvent<HTMLFormElement>) {
    event.preventDefault();
    const normalizedName = name.trim();
    if (!normalizedName || assetIDs.length === 0 || disabled || submitting) return;
    const frozenAssetIDs = [...assetIDs];
    const previous = operationRef.current;
    const operationID =
      previous?.name === normalizedName ? previous.operationID : crypto.randomUUID();
    operationRef.current = { name: normalizedName, operationID };
    setSubmitting(true);
    setFailure('');
    try {
      await onCreate(normalizedName, frozenAssetIDs, operationID);
      operationRef.current = null;
      restoreFocusRef.current = true;
      setName('');
    } catch (error) {
      setFailure(errorMessage(error));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form className="inline-tag-create" onSubmit={(event) => void submit(event)}>
      <label>
        <span>{inputLabel}</span>
        <input
          aria-label={inputLabel}
          disabled={disabled || submitting}
          onChange={(event) => {
            setName(event.target.value);
            setFailure('');
          }}
          onKeyDown={(event) => {
            if (event.key !== 'Escape' || (!name && !failure)) return;
            event.preventDefault();
            event.stopPropagation();
            operationRef.current = null;
            setName('');
            setFailure('');
          }}
          placeholder="输入新标签名称"
          ref={inputRef}
          value={name}
        />
      </label>
      <button
        aria-label={`创建并应用：${inputLabel}`}
        className="button"
        disabled={disabled || submitting || name.trim() === '' || assetIDs.length === 0}
        type="submit"
      >
        <Plus aria-hidden="true" size={14} /> {submitting ? '正在创建…' : '创建并应用'}
      </button>
      {failure ? (
        <p className="inline-tag-create-error" role="alert">
          {failure}
        </p>
      ) : null}
    </form>
  );
}

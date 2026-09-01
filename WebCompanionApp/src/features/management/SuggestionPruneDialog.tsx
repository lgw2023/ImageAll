import { useEffect, useRef, useState } from 'react';

import { ListX } from 'lucide-react';

import { errorMessage } from '@/api/errors';

export function SuggestionPruneDialog({
  tagName,
  methodName,
  effectiveMinScore,
  onCancel,
  onConfirm,
}: {
  tagName: string;
  methodName: string;
  effectiveMinScore: number;
  onCancel: () => void;
  onConfirm: (operationID: string) => Promise<void>;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const [operationID] = useState(() => crypto.randomUUID());
  const [submitting, setSubmitting] = useState(false);
  const [failure, setFailure] = useState('');

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    returnFocusRef.current =
      document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (!dialog.open) dialog.showModal();
    const frame = requestAnimationFrame(() => cancelRef.current?.focus());
    return () => {
      cancelAnimationFrame(frame);
      if (dialog.open) dialog.close();
      const target = returnFocusRef.current;
      requestAnimationFrame(() => {
        if (target?.isConnected) target.focus({ preventScroll: true });
      });
    };
  }, []);

  async function confirm() {
    setSubmitting(true);
    setFailure('');
    try {
      await onConfirm(operationID);
      onCancel();
    } catch (error) {
      setFailure(errorMessage(error));
      setSubmitting(false);
    }
  }

  return (
    <dialog
      aria-describedby="threshold-prune-description"
      aria-labelledby="threshold-prune-title"
      className="asset-deletion-dialog threshold-prune-dialog"
      onCancel={(event) => {
        event.preventDefault();
        if (!submitting) onCancel();
      }}
      ref={dialogRef}
      role="alertdialog"
    >
      <div className="asset-deletion-panel">
        <div aria-hidden="true" className="asset-deletion-icon">
          <ListX size={22} />
        </div>
        <div>
          <p className="eyebrow">更改审查队列</p>
          <h2 id="threshold-prune-title">
            清理“{tagName}”的{methodName}低分建议？
          </h2>
          <p id="threshold-prune-description">
            Mac 将移除当前有效门槛 {effectiveMinScore.toFixed(2)}
            及以下的待审建议。该操作不会修改门槛，也不会启动新的图库扫描；照片、标签决定与已完成记录不会被删除。
          </p>
        </div>
        {failure ? (
          <p className="asset-deletion-error" role="alert">
            {failure}
          </p>
        ) : null}
        <div className="asset-deletion-actions">
          <button
            className="button"
            disabled={submitting}
            onClick={onCancel}
            ref={cancelRef}
            type="button"
          >
            取消
          </button>
          <button
            className="button button-danger"
            disabled={submitting}
            onClick={() => void confirm()}
            type="button"
          >
            <ListX aria-hidden="true" size={15} />
            {submitting ? '正在清理…' : '确认清理低分待审项'}
          </button>
        </div>
      </div>
    </dialog>
  );
}

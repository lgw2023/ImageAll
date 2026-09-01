import { useEffect, useRef, useState } from 'react';

import { ShieldAlert, Trash2 } from 'lucide-react';

import { errorMessage } from '@/api/errors';

type AssetDeletionDialogProps = {
  fileName: string;
  onCancel: () => void;
  onConfirm: () => Promise<void>;
};

export function AssetDeletionDialog({ fileName, onCancel, onConfirm }: AssetDeletionDialogProps) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
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
      const returnTarget = returnFocusRef.current;
      requestAnimationFrame(() => {
        if (returnTarget?.isConnected) returnTarget.focus({ preventScroll: true });
      });
    };
  }, []);

  async function confirm() {
    setSubmitting(true);
    setFailure('');
    try {
      await onConfirm();
      onCancel();
    } catch (error) {
      setFailure(errorMessage(error));
      setSubmitting(false);
    }
  }

  return (
    <dialog
      aria-describedby="asset-deletion-description"
      aria-labelledby="asset-deletion-title"
      className="asset-deletion-dialog"
      onCancel={(event) => {
        event.preventDefault();
        if (!submitting) onCancel();
      }}
      ref={dialogRef}
      role="alertdialog"
    >
      <div className="asset-deletion-panel">
        <div aria-hidden="true" className="asset-deletion-icon">
          <ShieldAlert size={22} />
        </div>
        <div>
          <p className="eyebrow">需要 Mac 二次确认</p>
          <h2 id="asset-deletion-title">删除 {fileName}？</h2>
          <p id="asset-deletion-description">
            文件夹原始媒体可能永久删除；Apple Photos 将移入“最近删除”。红心项由 Host
            强制保护，提交后仍需回到 Mac 核对并确认。
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
            <Trash2 aria-hidden="true" size={15} />
            {submitting ? '正在提交…' : '提交给 Mac 确认删除'}
          </button>
        </div>
      </div>
    </dialog>
  );
}

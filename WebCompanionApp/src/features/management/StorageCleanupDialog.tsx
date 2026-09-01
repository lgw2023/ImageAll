import { useEffect, useRef, useState } from 'react';

import { ShieldAlert, Trash2 } from 'lucide-react';

import { errorMessage } from '@/api/errors';

export type StorageCleanupAction = 'clearPreviewCache' | 'clearPhotosOriginals';

const cleanupCopy: Record<
  StorageCleanupAction,
  { title: string; description: string; confirm: string }
> = {
  clearPreviewCache: {
    title: '清理预览缓存？',
    description:
      '只会删除可重建的网格缩略图和单图预览。原始照片、标签、Feature Print 与个人模型不会被删除。iCloud 预览之后需要再次手动获取。提交后仍需回到 Mac 核对并确认。',
    confirm: '提交给 Mac 确认清理',
  },
  clearPhotosOriginals: {
    title: '清理全部长期原图副本？',
    description:
      '只会删除 ImageAll 长期保留的 Apple Photos 原图副本。Apple Photos 原图、标签与分析结果不会被修改；以后分析时可能需要重新下载。提交后仍需回到 Mac 核对并确认。',
    confirm: '提交给 Mac 确认清理',
  },
};

export function StorageCleanupDialog({
  action,
  onCancel,
  onConfirm,
}: {
  action: StorageCleanupAction;
  onCancel: () => void;
  onConfirm: () => Promise<void>;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const cancelRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [failure, setFailure] = useState('');
  const copy = cleanupCopy[action];

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
      aria-describedby="storage-cleanup-description"
      aria-labelledby="storage-cleanup-title"
      className="asset-deletion-dialog storage-cleanup-dialog"
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
          <h2 id="storage-cleanup-title">{copy.title}</h2>
          <p id="storage-cleanup-description">{copy.description}</p>
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
            {submitting ? '正在提交…' : copy.confirm}
          </button>
        </div>
      </div>
    </dialog>
  );
}

import { useEffect, useRef } from 'react';

import { HardDriveDownload } from 'lucide-react';

export function PhotosOriginalStorageDialog({
  onDismiss,
  returnFocus,
}: {
  onDismiss: () => void;
  returnFocus: React.RefObject<HTMLElement | null>;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const dismissRef = useRef<HTMLButtonElement>(null);
  const returnFocusRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    returnFocusRef.current =
      returnFocus.current ??
      (document.activeElement instanceof HTMLElement ? document.activeElement : null);
    if (!dialog.open) dialog.showModal();
    const frame = requestAnimationFrame(() => dismissRef.current?.focus());
    return () => {
      cancelAnimationFrame(frame);
      if (dialog.open) dialog.close();
      const returnTarget = returnFocusRef.current;
      requestAnimationFrame(() => {
        if (returnTarget?.isConnected) returnTarget.focus({ preventScroll: true });
      });
    };
  }, [returnFocus]);

  return (
    <dialog
      aria-describedby="photos-original-storage-description"
      aria-labelledby="photos-original-storage-title"
      className="asset-deletion-dialog photos-original-storage-dialog"
      onCancel={(event) => {
        event.preventDefault();
        onDismiss();
      }}
      ref={dialogRef}
      role="alertdialog"
    >
      <div className="asset-deletion-panel">
        <div aria-hidden="true" className="asset-deletion-icon photos-original-storage-icon">
          <HardDriveDownload size={22} />
        </div>
        <div>
          <p className="eyebrow">需要在 Mac 上完成设置</p>
          <h2 id="photos-original-storage-title">需要设置 Photos 原图副本位置</h2>
          <p id="photos-original-storage-description">
            相同检测需要读取并保存 Apple Photos 的完整原图。请在 Mac App“设置 → 通用 → Photos
            原图副本”选择保存位置，重新启动 ImageAll 后再分析。当前分析尚未开始。
          </p>
        </div>
        <div className="asset-deletion-actions">
          <button
            className="button button-primary"
            onClick={onDismiss}
            ref={dismissRef}
            type="button"
          >
            暂不分析
          </button>
        </div>
      </div>
    </dialog>
  );
}

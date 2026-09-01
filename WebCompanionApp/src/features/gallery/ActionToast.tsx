import { RotateCcw } from 'lucide-react';

type ActionToastProps = {
  message: string;
  undoAvailable: boolean;
  undoPending: boolean;
  onDismiss: () => void;
  onUndo: () => void;
};

export function ActionToast({
  message,
  undoAvailable,
  undoPending,
  onDismiss,
  onUndo,
}: ActionToastProps) {
  return (
    <div className="action-toast" role="status">
      <span>{message}</span>
      {undoAvailable ? (
        <button className="button" disabled={undoPending} onClick={onUndo} type="button">
          <RotateCcw aria-hidden="true" size={14} /> 撤销
        </button>
      ) : null}
      <button aria-label="关闭消息" className="icon-button" onClick={onDismiss} type="button">
        ×
      </button>
    </div>
  );
}

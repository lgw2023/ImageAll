import { useMemo, useState, type SyntheticEvent } from 'react';

import { useQuery, useQueryClient } from '@tanstack/react-query';
import { Archive, Download, FolderPlus, Pencil, Trash2 } from 'lucide-react';

import type { TagGroupSummary, TagSummary } from '@/api/contracts/tag';
import { errorMessage } from '@/api/errors';
import {
  archiveTag,
  createTagGroup,
  deleteTagGroup,
  fetchTagGroups,
  fetchTags,
  installPresetTags,
  moveTag,
  renameTag,
  renameTagGroup,
} from '@/api/tags';

type TagEditorProps = {
  tag: TagSummary;
  groups: TagGroupSummary[];
  pending: boolean;
  onClose: () => void;
  onRun: (action: () => Promise<unknown>, success: string) => Promise<void>;
};

function TagEditor({ tag, groups, pending, onClose, onRun }: TagEditorProps) {
  const [name, setName] = useState(tag.displayName);
  const [groupID, setGroupID] = useState(tag.groupID);

  async function save(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return;
    try {
      if (trimmed !== tag.displayName) {
        await onRun(() => renameTag(tag.id, trimmed), `已将标签重命名为“${trimmed}”。`);
      }
      if (groupID !== tag.groupID) {
        await onRun(() => moveTag(tag.id, groupID), '已移动标签。');
      }
      onClose();
    } catch {
      // The visible status already explains the Host error.
    }
  }

  return (
    <form className="inline-editor" onSubmit={(event) => void save(event)}>
      <label>
        <span>名称</span>
        <input
          disabled={pending}
          onChange={(event) => setName(event.target.value)}
          required
          value={name}
        />
      </label>
      <label>
        <span>分组</span>
        <select
          disabled={pending}
          onChange={(event) => setGroupID(event.target.value)}
          value={groupID}
        >
          {groups.map((group) => (
            <option key={group.id} value={group.id}>
              {group.displayName}
            </option>
          ))}
        </select>
      </label>
      <div>
        <button className="button button-primary" disabled={pending} type="submit">
          保存
        </button>
        <button className="button" disabled={pending} onClick={onClose} type="button">
          取消
        </button>
        <button
          className="button button-danger"
          disabled={pending}
          onClick={() => {
            if (!window.confirm(`归档标签“${tag.displayName}”？现有照片决定不会被删除。`)) return;
            void onRun(() => archiveTag(tag.id), `已归档标签“${tag.displayName}”。`)
              .then(onClose)
              .catch(() => undefined);
          }}
          type="button"
        >
          <Archive aria-hidden="true" size={15} /> 归档
        </button>
      </div>
    </form>
  );
}

export function TagLibraryRoute() {
  const queryClient = useQueryClient();
  const [newGroupName, setNewGroupName] = useState('');
  const [editingTagID, setEditingTagID] = useState<string | null>(null);
  const [editingGroupID, setEditingGroupID] = useState<string | null>(null);
  const [groupDraft, setGroupDraft] = useState('');
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState('');
  const tags = useQuery({ queryKey: ['tags'], queryFn: ({ signal }) => fetchTags(signal) });
  const groups = useQuery({
    queryKey: ['tag-groups'],
    queryFn: ({ signal }) => fetchTagGroups(signal),
  });
  const tagsByGroup = useMemo(() => {
    const result = new Map<string, TagSummary[]>();
    for (const tag of tags.data ?? []) {
      const bucket = result.get(tag.groupID) ?? [];
      bucket.push(tag);
      result.set(tag.groupID, bucket);
    }
    return result;
  }, [tags.data]);

  async function run(action: () => Promise<unknown>, success: string) {
    setPending(true);
    setMessage('');
    try {
      await action();
      setMessage(success);
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: ['tags'] }),
        queryClient.invalidateQueries({ queryKey: ['tag-groups'] }),
        queryClient.invalidateQueries({ queryKey: ['review-overview'] }),
      ]);
    } catch (error) {
      setMessage(errorMessage(error));
      throw error;
    } finally {
      setPending(false);
    }
  }

  async function submitGroup(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    const name = newGroupName.trim();
    if (!name) return;
    try {
      await run(() => createTagGroup(name), `已创建分组“${name}”。`);
      setNewGroupName('');
    } catch {
      // The visible status already explains the Host error.
    }
  }

  if (tags.isPending || groups.isPending)
    return (
      <div className="workspace-state" role="status">
        正在载入标签库…
      </div>
    );
  if (tags.isError || groups.isError) {
    const failure = tags.error ?? groups.error;
    return (
      <div className="workspace-state workspace-state-error" role="alert">
        <strong>无法载入标签库</strong>
        <p>{errorMessage(failure)}</p>
        <button
          className="button"
          onClick={() => void Promise.all([tags.refetch(), groups.refetch()])}
          type="button"
        >
          重试
        </button>
      </div>
    );
  }

  return (
    <section className="domain-workspace tag-library-workspace" aria-labelledby="tag-library-title">
      <header className="domain-heading">
        <div>
          <p className="eyebrow">管理</p>
          <h2 id="tag-library-title">标签库</h2>
          <p>组织标签分组；所有改名、移动与归档由 Mac Host 持久化。</p>
        </div>
        <button
          className="button"
          disabled={pending}
          onClick={() =>
            void run(installPresetTags, '已安装缺少的预置标签。').catch(() => undefined)
          }
          type="button"
        >
          <Download aria-hidden="true" size={15} /> 安装预置
        </button>
      </header>

      <form className="create-row" onSubmit={(event) => void submitGroup(event)}>
        <label>
          <span className="visually-hidden">新分组名称</span>
          <input
            disabled={pending}
            onChange={(event) => setNewGroupName(event.target.value)}
            placeholder="新分组名称"
            value={newGroupName}
          />
        </label>
        <button
          className="button button-primary"
          disabled={pending || !newGroupName.trim()}
          type="submit"
        >
          <FolderPlus aria-hidden="true" size={15} /> 创建分组
        </button>
      </form>

      <div className="tag-group-list">
        {groups.data.map((group) => {
          const groupTags = tagsByGroup.get(group.id) ?? [];
          const editingGroup = editingGroupID === group.id;
          return (
            <section
              className="tag-group-panel"
              key={group.id}
              aria-labelledby={`tag-group-${group.id}`}
            >
              <header>
                {editingGroup ? (
                  <form
                    className="group-rename-form"
                    onSubmit={(event) => {
                      event.preventDefault();
                      const name = groupDraft.trim();
                      if (!name) return;
                      void run(() => renameTagGroup(group.id, name), `已将分组重命名为“${name}”。`)
                        .then(() => setEditingGroupID(null))
                        .catch(() => undefined);
                    }}
                  >
                    <input
                      aria-label="分组名称"
                      disabled={pending}
                      onChange={(event) => setGroupDraft(event.target.value)}
                      value={groupDraft}
                    />
                    <button className="button button-primary" disabled={pending} type="submit">
                      保存
                    </button>
                    <button
                      className="button"
                      onClick={() => setEditingGroupID(null)}
                      type="button"
                    >
                      取消
                    </button>
                  </form>
                ) : (
                  <div>
                    <h3 id={`tag-group-${group.id}`}>{group.displayName}</h3>
                    <span>{groupTags.length.toLocaleString('zh-CN')} 个标签</span>
                  </div>
                )}
                {!editingGroup && !group.isSystem ? (
                  <div className="panel-actions">
                    <button
                      aria-label={`重命名分组 ${group.displayName}`}
                      className="icon-button"
                      onClick={() => {
                        setEditingGroupID(group.id);
                        setGroupDraft(group.displayName);
                      }}
                      type="button"
                    >
                      <Pencil aria-hidden="true" size={15} />
                    </button>
                    <button
                      aria-label={`删除分组 ${group.displayName}`}
                      className="icon-button danger-icon"
                      disabled={pending}
                      onClick={() => {
                        if (
                          !window.confirm(
                            `删除分组“${group.displayName}”？其中标签将由 Host 按现有规则处理。`,
                          )
                        )
                          return;
                        void run(
                          () => deleteTagGroup(group.id),
                          `已删除分组“${group.displayName}”。`,
                        ).catch(() => undefined);
                      }}
                      type="button"
                    >
                      <Trash2 aria-hidden="true" size={15} />
                    </button>
                  </div>
                ) : null}
              </header>

              {groupTags.length ? (
                <div className="tag-rows">
                  {groupTags.map((tag) => (
                    <div className="tag-management-row" data-state={tag.state} key={tag.id}>
                      <div>
                        <strong>{tag.displayName}</strong>
                        <span>{tag.state === 'active' ? '使用中' : '已归档'}</span>
                      </div>
                      {editingTagID === tag.id ? (
                        <TagEditor
                          groups={groups.data}
                          onClose={() => setEditingTagID(null)}
                          onRun={run}
                          pending={pending}
                          tag={tag}
                        />
                      ) : tag.state === 'active' ? (
                        <button
                          className="button"
                          onClick={() => setEditingTagID(tag.id)}
                          type="button"
                        >
                          <Pencil aria-hidden="true" size={14} /> 编辑
                        </button>
                      ) : null}
                    </div>
                  ))}
                </div>
              ) : (
                <p className="panel-note">这个分组还没有标签。</p>
              )}
            </section>
          );
        })}
      </div>

      {message ? (
        <div className="action-toast" role="status">
          <span>{message}</span>
          <button
            aria-label="关闭消息"
            className="icon-button"
            onClick={() => setMessage('')}
            type="button"
          >
            ×
          </button>
        </div>
      ) : null}
    </section>
  );
}

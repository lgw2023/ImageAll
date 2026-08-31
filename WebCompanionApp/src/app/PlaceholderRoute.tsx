import type { ComponentType } from 'react';

type PlaceholderRouteProps = {
  eyebrow: string;
  title: string;
  description: string;
  icon: ComponentType<{ size?: number; 'aria-hidden'?: boolean }>;
};

export function PlaceholderRoute({
  eyebrow,
  title,
  description,
  icon: Icon,
}: PlaceholderRouteProps) {
  return (
    <section className="route-placeholder" aria-labelledby="route-title">
      <div className="route-heading">
        <div>
          <p className="eyebrow">{eyebrow}</p>
          <h2 id="route-title">{title}</h2>
          <p>{description}</p>
        </div>
        <button className="button" disabled type="button">
          功能迁移中
        </button>
      </div>
      <div className="empty-workbench">
        <Icon size={28} aria-hidden={true} />
        <h3>工作区已就绪</h3>
        <p>这个入口已纳入新的路由、会话与布局基座。完整流程在通过对齐门后接入。</p>
      </div>
    </section>
  );
}

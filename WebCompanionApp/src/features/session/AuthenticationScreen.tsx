import { useRef, useState, type KeyboardEvent, type SyntheticEvent } from 'react';

import { KeyRound, Laptop, Link2 } from 'lucide-react';

import { errorMessage } from '@/api/errors';
import { defaultDeviceName } from '@/api/session';

type AuthenticationScreenProps = {
  initialMessage?: string;
  onPair: (pairingToken: string, deviceName: string) => Promise<void>;
  onLogin: (username: string, password: string) => Promise<void>;
};

type Method = 'pair' | 'account';

function formString(data: FormData, name: string): string {
  const value = data.get(name);
  return typeof value === 'string' ? value : '';
}

export function AuthenticationScreen({
  initialMessage = '',
  onPair,
  onLogin,
}: AuthenticationScreenProps) {
  const [method, setMethod] = useState<Method>('pair');
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState(initialMessage);
  const [deviceName, setDeviceName] = useState(defaultDeviceName);
  const pairTab = useRef<HTMLButtonElement>(null);
  const accountTab = useRef<HTMLButtonElement>(null);

  function selectMethod(nextMethod: Method) {
    setMethod(nextMethod);
    if (nextMethod === 'pair') pairTab.current?.focus();
    else accountTab.current?.focus();
  }

  function handleTabKeyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    event.preventDefault();
    if (event.key === 'Home') selectMethod('pair');
    else if (event.key === 'End') selectMethod('account');
    else selectMethod(method === 'pair' ? 'account' : 'pair');
  }

  async function submitPair(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    setPending(true);
    setMessage('');
    try {
      await onPair(formString(data, 'pairingToken').trim(), deviceName.trim());
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending(false);
    }
  }

  async function submitAccount(event: SyntheticEvent<HTMLFormElement, SubmitEvent>) {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    setPending(true);
    setMessage('');
    try {
      await onLogin(formString(data, 'username').trim(), formString(data, 'password'));
      form.reset();
    } catch (error) {
      setMessage(errorMessage(error));
    } finally {
      setPending(false);
    }
  }

  return (
    <main className="authentication-shell" id="main-content">
      <section className="authentication-intro" aria-labelledby="authentication-title">
        <div className="brand-mark" aria-hidden="true">
          <Laptop size={24} />
        </div>
        <p className="eyebrow">ImageAll Web Companion</p>
        <h1 id="authentication-title">连接你的 Mac 照片工作台</h1>
        <p>
          图片、标签和操作结果仍由 Mac 上的 ImageAll 管理。网页不会把会话或私有媒体保存到本地缓存。
        </p>
        <ul className="authentication-facts">
          <li>同源加密会话</li>
          <li>高风险操作由 Mac 确认</li>
          <li>可随时在 Mac 上撤销设备</li>
        </ul>
      </section>

      <section className="authentication-card" aria-label="连接方式">
        <div className="segmented-control" role="tablist" aria-label="认证方式">
          <button
            aria-controls="pair-panel"
            aria-selected={method === 'pair'}
            className="segment"
            id="pair-tab"
            onClick={() => setMethod('pair')}
            onKeyDown={handleTabKeyDown}
            ref={pairTab}
            role="tab"
            tabIndex={method === 'pair' ? 0 : -1}
            type="button"
          >
            <Link2 size={16} aria-hidden="true" /> 配对码
          </button>
          <button
            aria-controls="account-panel"
            aria-selected={method === 'account'}
            className="segment"
            id="account-tab"
            onClick={() => setMethod('account')}
            onKeyDown={handleTabKeyDown}
            ref={accountTab}
            role="tab"
            tabIndex={method === 'account' ? 0 : -1}
            type="button"
          >
            <KeyRound size={16} aria-hidden="true" /> 账户
          </button>
        </div>

        {method === 'pair' ? (
          <form
            id="pair-panel"
            aria-labelledby="pair-tab"
            onSubmit={(event) => {
              void submitPair(event);
            }}
            role="tabpanel"
          >
            <div className="form-heading">
              <h2>使用 Mac 上的配对码</h2>
              <p>在 ImageAll 的远程访问设置中开始配对。</p>
            </div>
            <label>
              <span>配对码</span>
              <input autoComplete="one-time-code" name="pairingToken" required />
            </label>
            <label>
              <span>设备名称</span>
              <input
                autoComplete="off"
                maxLength={80}
                onChange={(event) => setDeviceName(event.target.value)}
                required
                value={deviceName}
              />
            </label>
            <button className="button button-primary" disabled={pending} type="submit">
              {pending ? '正在连接…' : '连接图库'}
            </button>
          </form>
        ) : (
          <form
            id="account-panel"
            aria-labelledby="account-tab"
            onSubmit={(event) => {
              void submitAccount(event);
            }}
            role="tabpanel"
          >
            <div className="form-heading">
              <h2>使用访问账户</h2>
              <p>账户必须已在 Mac 上的 ImageAll 白名单中。</p>
            </div>
            <label>
              <span>账户名</span>
              <input autoComplete="username" name="username" required />
            </label>
            <label>
              <span>密码</span>
              <input autoComplete="current-password" name="password" required type="password" />
            </label>
            <button className="button button-primary" disabled={pending} type="submit">
              {pending ? '正在登录…' : '登录图库'}
            </button>
          </form>
        )}
        <p aria-live="polite" className="form-error" role={message ? 'alert' : undefined}>
          {message}
        </p>
      </section>
    </main>
  );
}

import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, it, vi } from 'vitest';

import { AuthenticationScreen } from './AuthenticationScreen';

describe('AuthenticationScreen', () => {
  it('offers keyboard-reachable pairing and account forms', async () => {
    const user = userEvent.setup();
    render(<AuthenticationScreen onLogin={vi.fn()} onPair={vi.fn()} />);

    expect(screen.getByRole('heading', { name: '连接你的 Mac 照片工作台' })).toBeVisible();
    expect(screen.getByRole('textbox', { name: '配对码' })).toBeVisible();

    await user.click(screen.getByRole('tab', { name: '账户' }));
    expect(screen.getByRole('textbox', { name: '账户名' })).toBeVisible();
    expect(screen.getByLabelText('密码')).toHaveAttribute('type', 'password');
  });

  it('keeps rejected credentials on the same form with an alert', async () => {
    const user = userEvent.setup();
    render(
      <AuthenticationScreen
        onLogin={vi.fn().mockRejectedValue(new Error('账户名或密码不正确'))}
        onPair={vi.fn()}
      />,
    );
    await user.click(screen.getByRole('tab', { name: '账户' }));
    await user.type(screen.getByRole('textbox', { name: '账户名' }), 'reader');
    await user.type(screen.getByLabelText('密码'), 'incorrect');
    await user.click(screen.getByRole('button', { name: '登录图库' }));
    expect(await screen.findByRole('alert')).toHaveTextContent('账户名或密码不正确');
  });
});

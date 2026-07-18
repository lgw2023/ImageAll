from imageall_model_backend import cli


def test_cli_serves_only_on_loopback(monkeypatch) -> None:
    captured: dict[str, object] = {}

    def fake_run(app, *, host: str, port: int) -> None:
        captured.update(app=app, host=host, port=port)

    monkeypatch.setattr(cli.uvicorn, "run", fake_run)

    exit_code = cli.main(["--provider", "none", "--port", "9876"])

    assert exit_code == 0
    assert captured["host"] == "127.0.0.1"
    assert captured["port"] == 9876
    assert captured["app"] is not None

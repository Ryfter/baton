from hud.schema import normalize_hook, validate_envelope


def make_event(**overrides):
    event = {
        "schema": "hud.event/v1",
        "ts": "2026-09-09T07:40:00Z",
        "session_id": "abc123",
        "source": "claude-hook",
        "kind": "stop",
        "agent": "main",
        "machine": "droid",
        "payload": {},
    }
    event.update(overrides)
    return event


def test_validate_envelope_accepts_good():
    env = make_event(seq=1)
    assert validate_envelope(env) is env


def test_validate_envelope_rejects_missing_required():
    env = make_event(seq=1)
    del env["session_id"]
    try:
        validate_envelope(env)
        assert False, "expected ValueError"
    except ValueError as exc:
        assert "session_id" in str(exc)


def test_validate_envelope_rejects_missing_seq():
    env = make_event()
    try:
        validate_envelope(env)
        assert False, "expected ValueError"
    except ValueError as exc:
        assert "seq" in str(exc)


def test_validate_envelope_rejects_bad_schema():
    env = make_event(seq=1, schema="nope")
    try:
        validate_envelope(env)
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_normalize_session_start():
    out = normalize_hook(
        {
            "hook_event_name": "SessionStart",
            "session_id": "s1",
            "source": "resume",
            "cwd": "/tmp/proj",
        }
    )
    assert out["kind"] == "session_start"
    assert out["session_id"] == "s1"
    assert out["payload"]["source"] == "resume"
    assert out["payload"]["cwd"] == "/tmp/proj"


def test_normalize_user_prompt_truncated():
    prompt = "x" * 800
    out = normalize_hook(
        {
            "hook_event_name": "UserPromptSubmit",
            "session_id": "s1",
            "prompt": prompt,
        }
    )
    assert out["kind"] == "user_prompt"
    assert out["payload"]["prompt"] == "x" * 500


def test_normalize_pre_tool_use():
    out = normalize_hook(
        {
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": {"command": "ls -la"},
        }
    )
    assert out["kind"] == "pre_tool_use"
    assert out["payload"]["tool_name"] == "Bash"
    assert "ls -la" in out["payload"]["tool_input_summary"]


def test_normalize_post_tool_use():
    out = normalize_hook(
        {
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "tool_name": "Read",
            "tool_response": {"content": "ok"},
        }
    )
    assert out["kind"] == "post_tool_use"
    assert out["payload"]["tool_name"] == "Read"
    assert out["payload"]["ok"] is True
    assert "error" not in out["payload"]


def test_normalize_notification():
    out = normalize_hook(
        {
            "hook_event_name": "Notification",
            "session_id": "s1",
            "message": "needs you",
        }
    )
    assert out["kind"] == "notification"
    assert out["payload"]["message"] == "needs you"


def test_normalize_stop():
    out = normalize_hook({"hook_event_name": "Stop", "session_id": "s1"})
    assert out["kind"] == "stop"
    assert out["payload"] == {}


def test_normalize_subagent_stop():
    out = normalize_hook(
        {
            "hook_event_name": "SubagentStop",
            "session_id": "s1",
            "agent_id": "Explore",
        }
    )
    assert out["kind"] == "subagent_stop"
    assert out["payload"]["agent"] == "Explore"


def test_normalize_pre_compact():
    out = normalize_hook(
        {
            "hook_event_name": "PreCompact",
            "session_id": "s1",
            "trigger": "manual",
        }
    )
    assert out["kind"] == "pre_compact"
    assert out["payload"]["trigger"] == "manual"


def test_normalize_unknown_hook_fallback_not_dropped():
    out = normalize_hook(
        {
            "hook_event_name": "SomethingElse",
            "session_id": "keep-me",
            "message": "still stored",
        }
    )
    assert out["session_id"] == "keep-me"
    assert out["kind"] == "something_else"
    assert out["payload"]["message"] == "still stored"


def test_normalize_unknown_hook_truncates_unbounded_fields():
    out = normalize_hook(
        {
            "hook_event_name": "SomethingElse",
            "session_id": "keep-me",
            "message": "m" * 800,
            "cwd": "c" * 800,
            "prompt": "p" * 800,
        }
    )
    assert out["payload"]["message"] == "m" * 500
    assert out["payload"]["cwd"] == "c" * 500
    assert out["payload"]["prompt"] == "p" * 500

from dashboard.readers.display_goal import sanitize_goal


def test_strips_html_comments():
    raw = "<!-- Tonight 2026-08-23 --> Ship gauges page"
    assert sanitize_goal(raw) == "Ship gauges page"


def test_strips_repo_prefix():
    raw = "Repo: /Users/kev/Dev/baton Fix the parser"
    assert "Repo:" not in sanitize_goal(raw)
    assert "Fix the parser" in sanitize_goal(raw)


def test_strips_worktree_preferred_and_paths():
    raw = (
        "Worktree preferred: /Users/kev/Dev/.baton-worktrees/answerbot-ask "
        "(feat/student-ask-api) Ship student API"
    )
    out = sanitize_goal(raw)
    assert "/Users/kev" not in out
    assert "Worktree" not in out
    assert "Ship student API" in out


def test_strips_work_only_in_and_branch():
    raw = "Work only in: /Users/kev/Dev/WT Branch: WT-td-company Build tower slice"
    out = sanitize_goal(raw)
    assert "/Users/kev" not in out
    assert "Branch:" not in out
    assert "Build tower slice" in out


def test_truncates_long_goals():
    raw = "x" * 120
    assert len(sanitize_goal(raw)) == 90
    assert sanitize_goal(raw).endswith("…")

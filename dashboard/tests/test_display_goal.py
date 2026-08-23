from dashboard.readers.display_goal import sanitize_goal


def test_strips_html_comments():
    raw = "<!-- Tonight 2026-08-23 --> Ship gauges page"
    assert sanitize_goal(raw) == "Ship gauges page"


def test_strips_repo_prefix():
    raw = "Repo: /Users/kev/Dev/baton Fix the parser"
    assert "Repo:" not in sanitize_goal(raw)
    assert "Fix the parser" in sanitize_goal(raw)


def test_truncates_long_goals():
    raw = "x" * 120
    assert len(sanitize_goal(raw)) == 90
    assert sanitize_goal(raw).endswith("…")

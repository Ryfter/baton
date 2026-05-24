import pytest
from pathlib import Path

SAMPLE_JOURNAL = """\
# Model Routing Log

## Activity

2026-05-23T10:00:00-06:00 | hook | bash:ollama run devstral:24b 'Hello' | 2s | exit:0
2026-05-23T10:05:00-06:00 | otel | claude-sonnet-4-6 | in:3214 out:892 | $0.0231 | api_request
2026-05-23T10:10:00-06:00 | note | devstral | "used for smoke test"
2026-05-23T10:15:00-06:00 | otel | claude-haiku-4-5 | in:512 out:128 | $0.0011 | api_request
2026-05-23T10:20:00-06:00 | hook | bash:ollama run llava 'describe image' | 5s | exit:0
2026-05-23T10:25:00-06:00 | hook | agent:claude-subagent | 0s | exit:0 | "spec review task"
"""


@pytest.fixture
def journal_file(tmp_path: Path) -> Path:
    p = tmp_path / "model-routing-log.md"
    p.write_text(SAMPLE_JOURNAL, encoding="utf-8")
    return p

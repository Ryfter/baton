from __future__ import annotations

from pathlib import Path

from kb.chunker import chunk_file, chunk_text  # noqa: F401 — chunk_text is new


def test_chunk_text_direct_string() -> None:
    chunks = chunk_text("# Sec\n\nalpha body here", source="/virtual/x.pdf")
    assert len(chunks) >= 1
    assert chunks[0].source == "/virtual/x.pdf"
    assert "alpha" in "\n\n".join(c.text for c in chunks)


def test_chunk_file_routes_through_extractor(tmp_path, monkeypatch) -> None:
    import kb.chunker as chunker_mod
    fake = tmp_path / "doc.pdf"
    fake.write_bytes(b"%PDF-1.4")
    monkeypatch.setattr(chunker_mod, "extract_to_text", lambda p: "# T\n\nextracted body")
    chunks = chunk_file(fake)
    assert any("extracted body" in c.text for c in chunks)


def test_empty_file_no_chunks(tmp_path: Path) -> None:
    f = tmp_path / "x.md"
    f.write_text("", encoding="utf-8")
    assert chunk_file(f) == []


def test_whitespace_only_no_chunks(tmp_path: Path) -> None:
    f = tmp_path / "x.md"
    f.write_text("\n\n   \n", encoding="utf-8")
    assert chunk_file(f) == []


def test_no_headings_splits_by_paragraph(tmp_path: Path) -> None:
    f = tmp_path / "plain.md"
    # Two big paragraphs that should each be their own chunk
    para_a = "alpha " * 200          # ~1200 chars
    para_b = "beta " * 200
    f.write_text(f"{para_a}\n\n{para_b}", encoding="utf-8")
    chunks = chunk_file(f, max_chars=1500, overlap=200)
    assert len(chunks) >= 1
    joined = "\n\n".join(c.text for c in chunks)
    assert "alpha" in joined and "beta" in joined


def test_headings_define_chunk_boundaries(tmp_path: Path) -> None:
    f = tmp_path / "h.md"
    f.write_text(
        "# A\n\nbody of a\n\n## B\n\nbody of b\n\n## C\n\nbody of c",
        encoding="utf-8",
    )
    chunks = chunk_file(f, max_chars=1500, overlap=100)
    # Three sections → at least three chunks; none should contain another's heading text in body
    assert len(chunks) >= 3
    # No chunk should contain text from a different section
    for c in chunks:
        if "body of a" in c.text:
            assert "body of b" not in c.text and "body of c" not in c.text
        if "body of b" in c.text:
            assert "body of a" not in c.text and "body of c" not in c.text


def test_section_recorded(tmp_path: Path) -> None:
    f = tmp_path / "h.md"
    f.write_text("# Heading One\n\nalpha\n\n## Heading Two\n\nbeta", encoding="utf-8")
    chunks = chunk_file(f)
    sections = {c.section for c in chunks}
    assert "Heading One" in sections
    assert "Heading Two" in sections


def test_overlap_carries_context(tmp_path: Path) -> None:
    f = tmp_path / "long.md"
    # Many paragraphs all in one section, total well over max_chars
    paras = [f"paragraph-{i} " * 50 for i in range(20)]
    f.write_text("# Section\n\n" + "\n\n".join(paras), encoding="utf-8")
    chunks = chunk_file(f, max_chars=800, overlap=120)
    assert len(chunks) >= 2
    # Successive chunks should share at least some characters (overlap)
    for i in range(1, len(chunks)):
        prev_tail = chunks[i - 1].text[-100:]
        # Some non-trivial substring of prev_tail should appear in this chunk
        # Heuristic: at least one 20-char window matches
        matched = any(
            prev_tail[j:j + 20] in chunks[i].text
            for j in range(0, max(len(prev_tail) - 20, 1))
        )
        assert matched, f"chunks[{i}] missing overlap context"


def test_huge_paragraph_hard_wraps(tmp_path: Path) -> None:
    f = tmp_path / "huge.md"
    # One paragraph way over max_chars
    f.write_text("x" * 5000, encoding="utf-8")
    chunks = chunk_file(f, max_chars=1500, overlap=200)
    assert len(chunks) >= 3

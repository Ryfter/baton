"""Markdown-aware chunker. Heading-bounded, paragraph-respecting, overlap-friendly."""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

_HEADING_RE = re.compile(r'^(#{1,6})\s+(.+?)\s*$', re.MULTILINE)


@dataclass
class Chunk:
    source: str                 # absolute path string
    span: tuple[int, int]       # (char_start, char_end) into the original text
    text: str
    section: Optional[str]      # nearest preceding markdown heading text, or None


def _find_sections(text: str) -> list[tuple[int, str]]:
    """Return list of (char_offset, heading_text) for every markdown heading."""
    out: list[tuple[int, str]] = []
    for m in _HEADING_RE.finditer(text):
        out.append((m.start(), m.group(2).strip()))
    return out


def _section_for_offset(sections: list[tuple[int, str]], offset: int) -> Optional[str]:
    """Return the heading text whose offset is the latest preceding the given offset."""
    current: Optional[str] = None
    for off, head in sections:
        if off <= offset:
            current = head
        else:
            break
    return current


def _split_paragraphs(text: str) -> list[tuple[int, int, str]]:
    """Split on blank-line paragraph breaks. Returns (start, end, text) tuples."""
    out: list[tuple[int, int, str]] = []
    pos = 0
    # Normalize so blank-line splits work consistently
    for para in re.split(r'\n\s*\n', text):
        start = text.find(para, pos)
        if start == -1:
            start = pos
        end = start + len(para)
        if para.strip():
            out.append((start, end, para))
        pos = end
    return out


def chunk_file(
    path: Path,
    *,
    max_chars: int = 1500,
    overlap: int = 200,
) -> list[Chunk]:
    """Chunk a markdown (or plain text) file.

    Rules:
      - Chunks never cross a markdown heading boundary (sections are independent).
      - Within a section, paragraphs are accumulated until max_chars, then a new
        chunk starts with `overlap` trailing characters carried over for context.
      - Each chunk records its nearest preceding heading (section).
    """
    p = Path(path)
    raw = p.read_text(encoding='utf-8', errors='replace')
    if not raw.strip():
        return []

    src = str(p.resolve())
    sections = _find_sections(raw)

    # Build section boundaries: list of (start, end_exclusive). Last extends to EOF.
    boundaries: list[tuple[int, int]]
    if not sections:
        boundaries = [(0, len(raw))]
    else:
        boundaries = []
        # Region before the first heading (if any non-empty)
        if sections[0][0] > 0:
            boundaries.append((0, sections[0][0]))
        for i, (off, _) in enumerate(sections):
            end = sections[i + 1][0] if i + 1 < len(sections) else len(raw)
            boundaries.append((off, end))

    chunks: list[Chunk] = []
    for sec_start, sec_end in boundaries:
        section_text = raw[sec_start:sec_end]
        if not section_text.strip():
            continue

        # Carve into paragraphs (within this section only)
        paragraphs = _split_paragraphs(section_text)
        if not paragraphs:
            continue

        cur_start = paragraphs[0][0]   # relative to section_text
        cur_text_parts: list[str] = []
        cur_len = 0
        cur_end = cur_start

        def flush(start_rel: int, end_rel: int, text: str) -> None:
            abs_start = sec_start + start_rel
            abs_end = sec_start + end_rel
            section_head = _section_for_offset(sections, abs_start)
            chunks.append(Chunk(
                source=src,
                span=(abs_start, abs_end),
                text=text.strip(),
                section=section_head,
            ))

        for para_start, para_end, para_text in paragraphs:
            piece_len = len(para_text)
            # If a single paragraph exceeds max_chars on its own, split it raw
            if piece_len > max_chars:
                # Flush any pending accumulation first
                if cur_text_parts:
                    flush(cur_start, cur_end, '\n\n'.join(cur_text_parts))
                    cur_text_parts = []
                    cur_len = 0
                # Hard-wrap the giant paragraph
                step = max(max_chars - overlap, 1)
                offset = 0
                while offset < piece_len:
                    end_off = min(offset + max_chars, piece_len)
                    sub = para_text[offset:end_off]
                    abs_start = sec_start + para_start + offset
                    abs_end = sec_start + para_start + end_off
                    section_head = _section_for_offset(sections, abs_start)
                    chunks.append(Chunk(
                        source=src,
                        span=(abs_start, abs_end),
                        text=sub.strip(),
                        section=section_head,
                    ))
                    if end_off == piece_len:
                        break
                    offset += step
                cur_start = para_end
                cur_end = para_end
                continue

            # Normal accumulation
            if cur_len + piece_len + 2 > max_chars and cur_text_parts:
                flush(cur_start, cur_end, '\n\n'.join(cur_text_parts))
                # Start next chunk with overlap from the last accumulated text
                last_text = cur_text_parts[-1]
                tail = last_text[-overlap:] if len(last_text) > overlap else last_text
                cur_text_parts = [tail] if tail.strip() else []
                cur_len = len(tail)
                cur_start = max(cur_end - len(tail), 0)
            if not cur_text_parts:
                cur_start = para_start
            cur_text_parts.append(para_text)
            cur_len += piece_len + 2
            cur_end = para_end

        if cur_text_parts:
            flush(cur_start, cur_end, '\n\n'.join(cur_text_parts))

    return chunks

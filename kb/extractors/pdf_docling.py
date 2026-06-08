"""Docling PDF → markdown extractor. Docling is an OPTIONAL, lazily-imported dep."""
from __future__ import annotations

from pathlib import Path


def extract_pdf(path: Path) -> str:
    """Convert a PDF to markdown text via Docling.

    Raises kb.extractors.ExtractorUnavailable if Docling is not installed,
    kb.extractors.ExtractorError if conversion fails.
    """
    # Imported here (not at top) to avoid a circular import and to keep the
    # ExtractorUnavailable/ExtractorError types in one place.
    from kb.extractors import ExtractorError, ExtractorUnavailable

    try:
        from docling.document_converter import DocumentConverter
    except ImportError as e:
        raise ExtractorUnavailable(f"docling not installed: {e}") from e

    try:
        converter = DocumentConverter()
        result = converter.convert(str(path))
        return result.document.export_to_markdown()
    except Exception as e:  # noqa: BLE001 — any conversion failure
        raise ExtractorError(f"docling failed for {path}: {e}") from e

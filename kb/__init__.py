"""Plan 8: embedding-based KB retrieval.

Public API:
    chunk_file, Chunk          — kb.chunker
    embed                      — kb.embedder
    VectorStore, Hit           — kb.store
    Entry points:
        python -m kb.index     — walk corpus + embed + upsert
        python -m kb.search    — query top-k
"""
__version__ = "0.1.0"

"""Tests for parallel Ollama embedding processor."""
import pytest
from unittest.mock import MagicMock, patch
from adalflow.core.types import Document


def _make_doc(text: str, file_path: str = "test.py") -> Document:
    doc = Document(text=text, meta_data={"file_path": file_path})
    return doc


def _make_embedder_result(embedding):
    """Create a mock embedder result."""
    mock_result = MagicMock()
    if embedding is not None:
        mock_data = MagicMock()
        mock_data.embedding = embedding
        mock_result.data = [mock_data]
    else:
        mock_result.data = []
    return mock_result


class TestOllamaDocumentProcessor:
    def test_parallel_processing_basic(self):
        """Documents are embedded in parallel and results collected."""
        from api.ollama_patch import OllamaDocumentProcessor

        mock_embedder = MagicMock()
        embedding = [0.1, 0.2, 0.3]
        mock_embedder.side_effect = lambda input: _make_embedder_result(embedding)

        processor = OllamaDocumentProcessor(embedder=mock_embedder, max_workers=2)
        docs = [_make_doc(f"text {i}", f"file_{i}.py") for i in range(5)]
        result = processor(docs)

        assert len(result) == 5
        assert mock_embedder.call_count == 5
        for doc in result:
            assert doc.vector == embedding

    def test_inconsistent_embedding_size_skipped(self):
        """Documents with inconsistent embedding sizes are filtered out."""
        from api.ollama_patch import OllamaDocumentProcessor

        call_count = 0

        def mock_embed(input):
            nonlocal call_count
            call_count += 1
            # First call sets the expected size, third returns wrong size
            if call_count == 1:
                return _make_embedder_result([0.1, 0.2, 0.3])
            elif call_count == 3:
                return _make_embedder_result([0.1, 0.2])  # wrong size
            else:
                return _make_embedder_result([0.1, 0.2, 0.3])

        mock_embedder = MagicMock(side_effect=mock_embed)
        # Use max_workers=1 to ensure deterministic ordering
        processor = OllamaDocumentProcessor(embedder=mock_embedder, max_workers=1)
        docs = [_make_doc(f"text {i}") for i in range(4)]
        result = processor(docs)

        # One doc should be skipped due to size mismatch
        assert len(result) == 3

    def test_failed_embedding_skipped(self):
        """Documents that fail embedding are skipped gracefully."""
        from api.ollama_patch import OllamaDocumentProcessor

        mock_embedder = MagicMock()
        mock_embedder.side_effect = [
            _make_embedder_result([0.1, 0.2]),
            Exception("connection error"),
            _make_embedder_result([0.1, 0.2]),
        ]

        processor = OllamaDocumentProcessor(embedder=mock_embedder, max_workers=1)
        docs = [_make_doc(f"text {i}") for i in range(3)]
        result = processor(docs)

        assert len(result) == 2

    def test_empty_result_skipped(self):
        """Documents with empty embedding results are skipped."""
        from api.ollama_patch import OllamaDocumentProcessor

        mock_embedder = MagicMock()
        mock_embedder.side_effect = [
            _make_embedder_result([0.1, 0.2]),
            _make_embedder_result(None),  # empty result
            _make_embedder_result([0.1, 0.2]),
        ]

        processor = OllamaDocumentProcessor(embedder=mock_embedder, max_workers=1)
        docs = [_make_doc(f"text {i}") for i in range(3)]
        result = processor(docs)

        assert len(result) == 2

    def test_max_workers_from_env(self):
        """max_workers defaults to OLLAMA_EMBED_WORKERS env var."""
        from api.ollama_patch import OllamaDocumentProcessor

        with patch.dict("os.environ", {"OLLAMA_EMBED_WORKERS": "8"}):
            processor = OllamaDocumentProcessor(embedder=MagicMock())
            assert processor.max_workers == 8

    def test_max_workers_default(self):
        """max_workers defaults to DEFAULT_MAX_WORKERS when not configured."""
        from api.ollama_patch import OllamaDocumentProcessor

        with patch.dict("os.environ", {}, clear=True):
            # Remove env var if set
            import os
            os.environ.pop("OLLAMA_EMBED_WORKERS", None)
            processor = OllamaDocumentProcessor(embedder=MagicMock())
            assert processor.max_workers == OllamaDocumentProcessor.DEFAULT_MAX_WORKERS

    def test_max_workers_explicit(self):
        """Explicit max_workers overrides env var."""
        from api.ollama_patch import OllamaDocumentProcessor

        with patch.dict("os.environ", {"OLLAMA_EMBED_WORKERS": "8"}):
            processor = OllamaDocumentProcessor(embedder=MagicMock(), max_workers=2)
            assert processor.max_workers == 2

from typing import Sequence, List
from copy import deepcopy
from concurrent.futures import ThreadPoolExecutor, as_completed
from tqdm import tqdm
import logging
import adalflow as adal
from adalflow.core.types import Document
from adalflow.core.component import DataComponent
import requests
import os

# Configure logging
from api.logging_config import setup_logging

setup_logging()
logger = logging.getLogger(__name__)

class OllamaModelNotFoundError(Exception):
    """Custom exception for when Ollama model is not found"""
    pass

def check_ollama_model_exists(model_name: str, ollama_host: str = None) -> bool:
    """
    Check if an Ollama model exists before attempting to use it.
    
    Args:
        model_name: Name of the model to check
        ollama_host: Ollama host URL, defaults to localhost:11434
        
    Returns:
        bool: True if model exists, False otherwise
    """
    if ollama_host is None:
        ollama_host = os.getenv("OLLAMA_HOST", "http://localhost:11434")
    
    try:
        # Remove /api prefix if present and add it back
        if ollama_host.endswith('/api'):
            ollama_host = ollama_host[:-4]
        
        response = requests.get(f"{ollama_host}/api/tags", timeout=5)
        if response.status_code == 200:
            models_data = response.json()
            available_models = [model.get('name', '').split(':')[0] for model in models_data.get('models', [])]
            model_base_name = model_name.split(':')[0]  # Remove tag if present
            
            is_available = model_base_name in available_models
            if is_available:
                logger.info(f"Ollama model '{model_name}' is available")
            else:
                logger.warning(f"Ollama model '{model_name}' is not available. Available models: {available_models}")
            return is_available
        else:
            logger.warning(f"Could not check Ollama models, status code: {response.status_code}")
            return False
    except requests.exceptions.RequestException as e:
        logger.warning(f"Could not connect to Ollama to check models: {e}")
        return False
    except Exception as e:
        logger.warning(f"Error checking Ollama model availability: {e}")
        return False

class OllamaDocumentProcessor(DataComponent):
    """
    Process documents for Ollama embeddings with parallel execution.
    Adalflow Ollama Client does not support batch embedding, so we send
    individual requests but run them concurrently via a thread pool.
    """

    # Default number of parallel embedding requests
    DEFAULT_MAX_WORKERS = 4

    def __init__(self, embedder: adal.Embedder, max_workers: int = None) -> None:
        super().__init__()
        self.embedder = embedder
        self.max_workers = max_workers or int(
            os.getenv("OLLAMA_EMBED_WORKERS", self.DEFAULT_MAX_WORKERS)
        )

    def _embed_single(self, doc: Document, index: int):
        """Embed a single document. Returns (index, embedding) or (index, None)."""
        file_path = getattr(doc, 'meta_data', {}).get('file_path', f'document_{index}')
        try:
            result = self.embedder(input=doc.text)
            if result.data and len(result.data) > 0:
                return (index, result.data[0].embedding, file_path)
            else:
                logger.warning(f"Failed to get embedding for document '{file_path}', skipping")
                return (index, None, file_path)
        except Exception as e:
            logger.error(f"Error processing document '{file_path}': {e}, skipping")
            return (index, None, file_path)

    def __call__(self, documents: Sequence[Document]) -> Sequence[Document]:
        output = deepcopy(documents)
        n = len(output)
        logger.info(f"Processing {n} documents for Ollama embeddings (max_workers={self.max_workers})")

        successful_docs = []
        expected_embedding_size = None

        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = {
                executor.submit(self._embed_single, doc, i): i
                for i, doc in enumerate(output)
            }

            for future in tqdm(as_completed(futures), total=n, desc="Ollama embeddings"):
                index, embedding, file_path = future.result()

                if embedding is None:
                    continue

                # Validate embedding size consistency
                if expected_embedding_size is None:
                    expected_embedding_size = len(embedding)
                    logger.info(f"Expected embedding size set to: {expected_embedding_size}")
                elif len(embedding) != expected_embedding_size:
                    logger.warning(
                        f"Document '{file_path}' has inconsistent embedding size "
                        f"{len(embedding)} != {expected_embedding_size}, skipping"
                    )
                    continue

                output[index].vector = embedding
                successful_docs.append(output[index])

        logger.info(f"Successfully processed {len(successful_docs)}/{n} documents with consistent embeddings")
        return successful_docs
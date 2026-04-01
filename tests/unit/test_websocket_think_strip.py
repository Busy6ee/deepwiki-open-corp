"""Tests for think-tag stripping utility."""
import pytest
from api.websocket_wiki import strip_think_tags


def test_strip_think_tags_removes_tags():
    text = "<think>internal reasoning</think>Hello world"
    assert strip_think_tags(text) == "Hello world"


def test_strip_think_tags_removes_multiline():
    text = "<think>\nstep 1\nstep 2\n</think>\n<wiki_structure>"
    assert strip_think_tags(text) == "\n<wiki_structure>"


def test_strip_think_tags_no_tags():
    text = "<wiki_structure><title>Test</title></wiki_structure>"
    assert strip_think_tags(text) == "<wiki_structure><title>Test</title></wiki_structure>"


def test_strip_think_tags_empty():
    assert strip_think_tags("") == ""


def test_strip_think_tags_nested_content():
    text = "<think>reasoning about <xml> tags</think>actual content"
    assert strip_think_tags(text) == "actual content"

"""
Unit tests for Memory Management (Task 16.4).

Tests WindowMemory and BufferMemory strategies for L4 conversation state.
"""

import pytest
import sys
from pathlib import Path
from datetime import datetime

# Add src to path
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "src"))

from memory import ConversationTurn, MemoryManager, BufferMemory, WindowMemory


def make_turn(turn_id: int, query: str = "test query", response: str = "test response") -> ConversationTurn:
    """Helper to create a ConversationTurn."""
    return ConversationTurn(
        turn_id=turn_id,
        timestamp=datetime.now(),
        query=query,
        response=response,
        context_used=["source.md"]
    )


class TestConversationTurn:
    """Test ConversationTurn dataclass."""

    def test_turn_creation(self):
        """Test that a ConversationTurn can be created with expected fields."""
        turn = make_turn(1, "Who is Team Platform lead?", "Alex Chen")
        assert turn.turn_id == 1
        assert turn.query == "Who is Team Platform lead?"
        assert turn.response == "Alex Chen"
        assert isinstance(turn.timestamp, datetime)
        assert turn.context_used == ["source.md"]


class TestBufferMemory:
    """Test BufferMemory — stores all turns, returns all."""

    def setup_method(self):
        self.memory = BufferMemory()
        self.session = "session-buffer-1"

    def test_save_and_retrieve_turn(self):
        """Test save_turn() and get_history() roundtrip."""
        turn = make_turn(1)
        self.memory.save_turn(self.session, turn)
        history = self.memory.get_history(self.session)
        assert len(history) == 1
        assert history[0].turn_id == 1

    def test_multiple_turns_in_order(self):
        """Test that turns are stored and returned in insertion order."""
        for i in range(1, 4):
            self.memory.save_turn(self.session, make_turn(i, f"query {i}", f"response {i}"))

        history = self.memory.get_history(self.session)
        assert len(history) == 3
        assert [t.turn_id for t in history] == [1, 2, 3]

    def test_get_history_empty_session(self):
        """Test that a new session returns empty history."""
        history = self.memory.get_history("unknown-session")
        assert history == []

    def test_get_history_last_n(self):
        """Test that last_n parameter limits returned turns."""
        for i in range(1, 6):
            self.memory.save_turn(self.session, make_turn(i))

        history = self.memory.get_history(self.session, last_n=3)
        assert len(history) == 3
        assert history[0].turn_id == 3

    def test_format_for_llm_empty(self):
        """Test format_for_llm returns empty string for empty history."""
        result = self.memory.format_for_llm([])
        assert result == ""

    def test_format_for_llm_contains_queries_and_responses(self):
        """Test format_for_llm includes User and Assistant lines."""
        turns = [
            make_turn(1, "Which service is most expensive?", "PaymentGW"),
            make_turn(2, "Why did its costs spike?", "Due to scaling event"),
        ]
        result = self.memory.format_for_llm(turns)
        assert "Which service is most expensive?" in result
        assert "PaymentGW" in result
        assert "Why did its costs spike?" in result
        assert "Due to scaling event" in result
        # Should have some kind of User/Assistant labels
        assert "User:" in result or "user" in result.lower()

    def test_clear_session(self):
        """Test clear_session removes all turns."""
        for i in range(1, 4):
            self.memory.save_turn(self.session, make_turn(i))

        self.memory.clear_session(self.session)
        history = self.memory.get_history(self.session)
        assert history == []

    def test_clear_nonexistent_session_no_error(self):
        """Test clearing a non-existent session doesn't raise."""
        self.memory.clear_session("nonexistent-session")  # Should not raise

    def test_multiple_sessions_isolated(self):
        """Test that different sessions don't share state."""
        session_a = "session-a"
        session_b = "session-b"
        self.memory.save_turn(session_a, make_turn(1, "query A"))
        self.memory.save_turn(session_b, make_turn(1, "query B"))

        assert self.memory.get_history(session_a)[0].query == "query A"
        assert self.memory.get_history(session_b)[0].query == "query B"


class TestWindowMemory:
    """Test WindowMemory — stores all turns, returns only last N."""

    def setup_method(self):
        self.window_size = 3
        self.memory = WindowMemory(window_size=self.window_size)
        self.session = "session-window-1"

    def test_window_limits_to_last_n_turns(self):
        """Test that get_history returns only last window_size turns."""
        for i in range(1, 8):  # 7 turns
            self.memory.save_turn(self.session, make_turn(i))

        history = self.memory.get_history(self.session)
        assert len(history) == self.window_size
        # Should be the last 3: turns 5, 6, 7
        assert [t.turn_id for t in history] == [5, 6, 7]

    def test_window_fewer_turns_than_window(self):
        """Test that if fewer turns exist than window_size, all are returned."""
        self.memory.save_turn(self.session, make_turn(1))
        self.memory.save_turn(self.session, make_turn(2))

        history = self.memory.get_history(self.session)
        assert len(history) == 2

    def test_all_turns_still_stored(self):
        """Test that all turns are stored internally even if not all returned."""
        for i in range(1, 8):
            self.memory.save_turn(self.session, make_turn(i))

        # Override window with last_n to see all
        all_history = self.memory.get_history(self.session, last_n=10)
        assert len(all_history) == 7

    def test_save_and_retrieve_turn(self):
        """Test basic save and retrieve."""
        turn = make_turn(1, "Test query", "Test answer")
        self.memory.save_turn(self.session, turn)
        history = self.memory.get_history(self.session)
        assert len(history) == 1
        assert history[0].query == "Test query"

    def test_format_for_llm_shows_window_label(self):
        """Test format_for_llm mentions recent turns."""
        turns = [make_turn(i) for i in range(1, 4)]
        result = self.memory.format_for_llm(turns)
        assert "User:" in result or "user" in result.lower()
        assert result != ""

    def test_format_for_llm_empty_returns_empty_string(self):
        """Test format_for_llm returns empty string when no history."""
        result = self.memory.format_for_llm([])
        assert result == ""

    def test_clear_session(self):
        """Test clear_session wipes all turns."""
        for i in range(1, 5):
            self.memory.save_turn(self.session, make_turn(i))

        self.memory.clear_session(self.session)
        history = self.memory.get_history(self.session)
        assert history == []

    def test_multiple_sessions_isolated(self):
        """Test isolation between different sessions."""
        session_x = "window-x"
        session_y = "window-y"
        self.memory.save_turn(session_x, make_turn(1, "query X"))
        self.memory.save_turn(session_y, make_turn(1, "query Y"))

        assert self.memory.get_history(session_x)[0].query == "query X"
        assert self.memory.get_history(session_y)[0].query == "query Y"

    def test_window_size_configurable(self):
        """Test that window_size can be set at init."""
        memory_5 = WindowMemory(window_size=5)
        memory_2 = WindowMemory(window_size=2)
        session = "cfg-test"

        for i in range(1, 7):
            memory_5.save_turn(session, make_turn(i))
            memory_2.save_turn(session, make_turn(i))

        assert len(memory_5.get_history(session)) == 5
        assert len(memory_2.get_history(session)) == 2


class TestMemoryManagerInterface:
    """Test that MemoryManager base class raises NotImplementedError for all methods."""

    def test_base_class_raises(self):
        """Test abstract interface raises NotImplementedError."""
        base = MemoryManager()
        turn = make_turn(1)
        with pytest.raises(NotImplementedError):
            base.save_turn("session", turn)
        with pytest.raises(NotImplementedError):
            base.get_history("session")
        with pytest.raises(NotImplementedError):
            base.format_for_llm([])
        with pytest.raises(NotImplementedError):
            base.clear_session("session")


if __name__ == "__main__":
    pytest.main([__file__, "-v"])

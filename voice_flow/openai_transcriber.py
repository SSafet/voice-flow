from __future__ import annotations

import io
import http.client
import json
import re
import time
import uuid
import urllib.error
import urllib.request
import wave
from collections.abc import Callable

import numpy as np

from voice_flow.config import OPENAI_STT_MODEL, SAMPLE_RATE, FILLER_ONLY


class OpenAITranscriber:
    """OpenAI speech-to-text via the /v1/audio/transcriptions endpoint."""

    def __init__(self, model_name: str = OPENAI_STT_MODEL):
        self.model_name = model_name

    def transcribe(
        self,
        audio: np.ndarray,
        api_key: str,
        sample_rate: int = SAMPLE_RATE,
        vocabulary: list[str] | None = None,
        wake_word: str | None = None,
        max_attempts: int = 3,
        on_retry: Callable[[int, int], None] | None = None,
        on_delta: Callable[[str], None] | None = None,
        timeout_seconds: float = 90,
    ) -> str:
        if not api_key.strip():
            raise ValueError("Missing OpenAI API key")
        if len(audio) == 0:
            return ""

        wav_bytes = _audio_to_wav_bytes(audio, sample_rate)
        fields: dict[str, str] = {
            "model": self.model_name,
            "response_format": "json",
        }
        if on_delta is not None:
            fields["stream"] = "true"
        prompt = _transcription_prompt(vocabulary, wake_word)
        if prompt:
            fields["prompt"] = prompt

        body, content_type = _build_multipart_body(
            fields=fields,
            file_field="file",
            file_name="dictation.wav",
            file_bytes=wav_bytes,
            mime_type="audio/wav",
        )

        request = urllib.request.Request(
            "https://api.openai.com/v1/audio/transcriptions",
            data=body,
            headers={
                "Authorization": f"Bearer {api_key.strip()}",
                "Content-Type": content_type,
            },
            method="POST",
        )

        # Replay the same saved request on transient transport/provider errors.
        # RemoteDisconnected is NOT a URLError: it was escaping immediately and
        # turning a single dropped connection into a failed final dictation.
        attempts = max(1, min(max_attempts, 3))
        for attempt in range(1, attempts + 1):
            try:
                with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
                    payload = (_read_transcript_stream(response, on_delta) if on_delta is not None
                               else json.loads(response.read().decode("utf-8")))
                break
            except urllib.error.HTTPError as exc:
                detail = exc.read().decode("utf-8", errors="replace")
                exc.close()
                try:
                    parsed = json.loads(detail)
                    message = parsed.get("error", {}).get("message", detail)
                except (json.JSONDecodeError, AttributeError):
                    message = detail
                retryable = exc.code in (408, 429) or 500 <= exc.code < 600
                if not retryable or attempt == attempts:
                    raise RuntimeError(f"OpenAI transcription failed ({exc.code}): {message}") from exc
            except (urllib.error.URLError, ConnectionError, TimeoutError,
                    http.client.IncompleteRead) as exc:
                if attempt == attempts:
                    reason = getattr(exc, "reason", str(exc))
                    raise RuntimeError(
                        f"OpenAI transcription failed after {attempt} attempt(s): {reason}") from exc
            if on_delta is not None:
                on_delta("")  # Reset provisional text before replaying the saved audio.
            if on_retry:
                on_retry(attempt + 1, attempts)
            time.sleep(attempt)

        text = str(payload.get("text", "")).strip()
        if text.lower().strip(".,!?") in FILLER_ONLY:
            return ""
        if _is_prompt_echo(text, vocabulary, wake_word):
            return ""
        return text


def _read_transcript_stream(response, on_delta) -> dict:
    """SSE frames are line-delimited, not TCP-chunk-delimited. Only done commits.

    The callback receives replacement text, so retries cannot duplicate a prefix.
    An interrupted stream is a transport failure and uses the existing retry path.
    """
    text = ""
    event_lines = []
    for raw in response:
        line = raw.decode("utf-8").rstrip("\r\n")
        if line.startswith("data:"):
            event_lines.append(line[5:].lstrip())
        elif not line and event_lines:
            data = "\n".join(event_lines)
            event_lines = []
            if data == "[DONE]":
                break
            event = json.loads(data)
            kind = event.get("type")
            if kind == "transcript.text.delta":
                text += event.get("delta", "")
                on_delta(text)
            elif kind == "transcript.text.done":
                return {"text": event.get("text", text)}
            elif kind == "error":
                raise RuntimeError("OpenAI transcription stream failed: " + str(event.get("message", "unknown error")))
    raise http.client.IncompleteRead(b"", None)


def _normalize(s: str) -> str:
    return " ".join(re.sub(r"[^\w\s'-]", " ", s.lower()).split())


def _transcription_prompt(
    vocabulary: list[str] | None,
    wake_word: str | None,
) -> str:
    parts: list[str] = []
    wake_word = (wake_word or "").strip()
    if wake_word:
        parts.append(
            f'The assistant wake name is written exactly as "{wake_word}". '
            f'Preserve the spelling and script "{wake_word}" even when the '
            "surrounding speech uses another language."
        )
    if vocabulary:
        parts.append("Correct spellings: " + ", ".join(vocabulary))
    return " ".join(parts)


def _is_prompt_echo(
    text: str,
    vocabulary: list[str] | None,
    wake_word: str | None,
) -> bool:
    """On short or unintelligible audio the model completes the vocabulary
    prompt instead of transcribing, pasting the keyword list at the user.
    An echo is a verbatim run of the prompt — real dictation that merely
    uses vocab words has its own words around them, and a single vocab word
    alone is legitimate dictation, so neither is flagged."""
    t = _normalize(text)
    if not t:
        return False
    if "assistant wake name" in t or "correct spellings" in t:
        return True
    if not vocabulary:
        return False
    hits = sum(1 for w in vocabulary if _normalize(w) and _normalize(w) in t)
    if hits < 2:
        return False
    # Every transcript word appears in the prompt, in prompt order
    # (an echo may skip list items but never adds words of its own).
    prompt_words = iter(_normalize(", ".join(vocabulary)).split())
    return all(word in prompt_words for word in t.split())


def _audio_to_wav_bytes(audio: np.ndarray, sample_rate: int) -> bytes:
    clipped = np.clip(audio, -1.0, 1.0)
    audio_int16 = (clipped * 32767).astype(np.int16)

    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(1)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(audio_int16.tobytes())
    return buffer.getvalue()


def _build_multipart_body(
    *,
    fields: dict[str, str],
    file_field: str,
    file_name: str,
    file_bytes: bytes,
    mime_type: str,
) -> tuple[bytes, str]:
    boundary = f"voiceflow-{uuid.uuid4().hex}"
    lines: list[bytes] = []

    for name, value in fields.items():
        lines.extend(
            [
                f"--{boundary}".encode("utf-8"),
                f'Content-Disposition: form-data; name="{name}"'.encode("utf-8"),
                b"",
                str(value).encode("utf-8"),
            ]
        )

    lines.extend(
        [
            f"--{boundary}".encode("utf-8"),
            (
                f'Content-Disposition: form-data; name="{file_field}"; '
                f'filename="{file_name}"'
            ).encode("utf-8"),
            f"Content-Type: {mime_type}".encode("utf-8"),
            b"",
            file_bytes,
            f"--{boundary}--".encode("utf-8"),
            b"",
        ]
    )

    return b"\r\n".join(lines), f"multipart/form-data; boundary={boundary}"

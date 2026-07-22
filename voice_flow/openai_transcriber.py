from __future__ import annotations

import io
import json
import re
import uuid
import urllib.error
import urllib.request
import wave

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

        try:
            with urllib.request.urlopen(request, timeout=90) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            try:
                parsed = json.loads(detail)
                message = parsed.get("error", {}).get("message", detail)
            except json.JSONDecodeError:
                message = detail
            raise RuntimeError(f"OpenAI transcription failed ({exc.code}): {message}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"OpenAI transcription failed: {exc.reason}") from exc

        text = str(payload.get("text", "")).strip()
        if text.lower().strip(".,!?") in FILLER_ONLY:
            return ""
        if _is_prompt_echo(text, vocabulary, wake_word):
            return ""
        return text


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

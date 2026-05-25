"""VS Code Copilot bridge model provider.

This provider lets DeerFlow use GitHub Copilot chat models exposed by VS Code's
official Language Model API. DeerFlow talks to a local loopback bridge instead
of reading VS Code or Copilot credentials directly.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

import httpx
from langchain_core.callbacks import AsyncCallbackManagerForLLMRun, CallbackManagerForLLMRun
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import AIMessage, BaseMessage
from langchain_core.outputs import ChatGeneration, ChatResult
from langchain_core.runnables import RunnableBinding
from langchain_core.tools import BaseTool
from langchain_core.utils.function_calling import convert_to_openai_function
from pydantic import Field

from deerflow.runtime.converters import langchain_messages_to_openai

logger = logging.getLogger(__name__)


_SUPPORTED_REASONING_EFFORTS = {"none", "minimal", "low", "medium", "high", "xhigh"}


def _deep_merge_dicts(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = _deep_merge_dicts(merged[key], value)
        else:
            merged[key] = value
    return merged


def _build_usage_metadata(usage: dict[str, Any]) -> dict[str, Any] | None:
    if not usage:
        return None
    input_tokens = usage.get("prompt_tokens") or usage.get("input_tokens") or 0
    output_tokens = usage.get("completion_tokens") or usage.get("output_tokens") or 0
    total_tokens = usage.get("total_tokens") or input_tokens + output_tokens
    return {
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": total_tokens,
    }


def _normalize_reasoning_effort(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    if normalized in _SUPPORTED_REASONING_EFFORTS:
        return normalized
    return None


class VSCodeCopilotChatModel(BaseChatModel):
    """LangChain chat model backed by a local VS Code Copilot bridge.

    Config example:

        - name: vscode-copilot
          use: deerflow.models.vscode_copilot_provider:VSCodeCopilotChatModel
            model: gpt-5.4
          base_url: http://127.0.0.1:8765
          request_timeout: 600.0
            supports_reasoning_effort: true
            reasoning_effort: xhigh
    """

    model: str = "copilot-auto"
    base_url: str = "http://127.0.0.1:8765"
    chat_completions_path: str = "/v1/chat/completions"
    api_key: str | None = None
    request_timeout: float = 600.0
    max_retries: int = 2
    retry_backoff_seconds: float = 1.0
    temperature: float | None = None
    max_tokens: int | None = None
    top_p: float | None = None
    reasoning_effort: str | None = None
    extra_body: dict[str, Any] | None = Field(default=None)

    model_config = {"arbitrary_types_allowed": True, "extra": "allow"}

    @property
    def _llm_type(self) -> str:
        return "vscode-copilot-bridge"

    @classmethod
    def is_lc_serializable(cls) -> bool:
        return True

    def _endpoint_url(self) -> str:
        base_url = self.base_url.rstrip("/")
        path = self.chat_completions_path
        if not path.startswith("/"):
            path = f"/{path}"
        return f"{base_url}{path}"

    def _headers(self) -> dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _build_payload(self, messages: list[BaseMessage], stop: list[str] | None, kwargs: dict[str, Any]) -> dict[str, Any]:
        reasoning_effort = _normalize_reasoning_effort(kwargs.get("reasoning_effort"))
        if reasoning_effort is None:
            reasoning_effort = _normalize_reasoning_effort(self.reasoning_effort)

        payload: dict[str, Any] = {
            "model": self.model,
            "messages": langchain_messages_to_openai(messages),
            "stream": False,
        }
        if stop:
            payload["stop"] = stop
        if self.temperature is not None:
            payload["temperature"] = self.temperature
        if self.max_tokens is not None:
            payload["max_tokens"] = self.max_tokens
        if self.top_p is not None:
            payload["top_p"] = self.top_p
        if reasoning_effort is not None:
            payload["reasoning_effort"] = reasoning_effort
        if tools := kwargs.get("tools"):
            payload["tools"] = tools
        if tool_choice := kwargs.get("tool_choice"):
            payload["tool_choice"] = tool_choice
        if self.extra_body:
            payload = _deep_merge_dicts(payload, self.extra_body)
        return payload

    def _is_retryable_http_error(self, exc: httpx.HTTPStatusError) -> bool:
        return exc.response.status_code == 429 or exc.response.status_code >= 500

    def _bridge_failure(self, exc: Exception) -> RuntimeError:
        detail = str(exc).strip() or exc.__class__.__name__
        if isinstance(exc, httpx.HTTPStatusError):
            response_text = exc.response.text[:500]
            detail = f"HTTP {exc.response.status_code}: {response_text}"
        elif isinstance(exc, httpx.TimeoutException):
            detail = (
                f"{detail}. The bridge accepted the connection but no Copilot response arrived before the timeout. "
                "This usually means the Extension Development Host window still needs Copilot access approval, "
                "or an older bridge build is still running."
            )
        return RuntimeError(f"VS Code Copilot bridge request failed. Start the bridge extension with 'DeerFlow Copilot Bridge: Start' and confirm VS Code Copilot model access. Details: {detail}")

    def _post_chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        last_error: Exception | None = None
        retry_count = max(1, self.max_retries)
        for attempt in range(1, retry_count + 1):
            try:
                with httpx.Client(timeout=self.request_timeout) as client:
                    response = client.post(self._endpoint_url(), headers=self._headers(), json=payload)
                response.raise_for_status()
                data = response.json()
                if not isinstance(data, dict):
                    raise ValueError("Bridge returned a non-object JSON response")
                return data
            except httpx.HTTPStatusError as exc:
                last_error = exc
                if attempt >= retry_count or not self._is_retryable_http_error(exc):
                    raise self._bridge_failure(exc) from exc
            except (httpx.HTTPError, json.JSONDecodeError, ValueError) as exc:
                last_error = exc
                if attempt >= retry_count:
                    raise self._bridge_failure(exc) from exc
            time.sleep(self.retry_backoff_seconds * attempt)

        raise self._bridge_failure(last_error or RuntimeError("unknown bridge error"))

    async def _apost_chat_completion(self, payload: dict[str, Any]) -> dict[str, Any]:
        last_error: Exception | None = None
        retry_count = max(1, self.max_retries)
        for attempt in range(1, retry_count + 1):
            try:
                async with httpx.AsyncClient(timeout=self.request_timeout) as client:
                    response = await client.post(self._endpoint_url(), headers=self._headers(), json=payload)
                response.raise_for_status()
                data = response.json()
                if not isinstance(data, dict):
                    raise ValueError("Bridge returned a non-object JSON response")
                return data
            except httpx.HTTPStatusError as exc:
                last_error = exc
                if attempt >= retry_count or not self._is_retryable_http_error(exc):
                    raise self._bridge_failure(exc) from exc
            except (httpx.HTTPError, json.JSONDecodeError, ValueError) as exc:
                last_error = exc
                if attempt >= retry_count:
                    raise self._bridge_failure(exc) from exc
            await asyncio.sleep(self.retry_backoff_seconds * attempt)

        raise self._bridge_failure(last_error or RuntimeError("unknown bridge error"))

    @staticmethod
    def _normalize_content(content: Any) -> str:
        if content is None:
            return ""
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for item in content:
                if isinstance(item, dict) and item.get("type") in ("text", "output_text"):
                    parts.append(str(item.get("text", "")))
                elif isinstance(item, str):
                    parts.append(item)
            return "".join(parts)
        return str(content)

    @staticmethod
    def _parse_tool_call(raw_tool_call: dict[str, Any]) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
        function = raw_tool_call.get("function") or {}
        name = function.get("name") or raw_tool_call.get("name")
        arguments = function.get("arguments") or raw_tool_call.get("arguments") or "{}"
        if isinstance(arguments, dict):
            parsed_arguments = arguments
        else:
            try:
                parsed_arguments = json.loads(arguments)
            except (TypeError, json.JSONDecodeError) as exc:
                return None, {
                    "type": "invalid_tool_call",
                    "name": name,
                    "args": str(arguments),
                    "id": raw_tool_call.get("id"),
                    "error": f"Failed to parse tool arguments: {exc}",
                }
        if not isinstance(parsed_arguments, dict):
            return None, {
                "type": "invalid_tool_call",
                "name": name,
                "args": str(arguments),
                "id": raw_tool_call.get("id"),
                "error": "Tool arguments must decode to a JSON object.",
            }
        return {
            "name": name or "",
            "args": parsed_arguments,
            "id": raw_tool_call.get("id", ""),
            "type": "tool_call",
        }, None

    def _parse_response(self, response: dict[str, Any]) -> ChatResult:
        choices = response.get("choices") or []
        if not choices:
            raise RuntimeError(f"VS Code Copilot bridge response has no choices: {response}")
        choice = choices[0]
        message = choice.get("message") or {}
        raw_tool_calls = message.get("tool_calls") or []

        tool_calls = []
        invalid_tool_calls = []
        for raw_tool_call in raw_tool_calls:
            if not isinstance(raw_tool_call, dict):
                continue
            tool_call, invalid_tool_call = self._parse_tool_call(raw_tool_call)
            if tool_call:
                tool_calls.append(tool_call)
            if invalid_tool_call:
                invalid_tool_calls.append(invalid_tool_call)

        usage = response.get("usage") or {}
        additional_kwargs: dict[str, Any] = {}
        if raw_tool_calls:
            additional_kwargs["tool_calls"] = raw_tool_calls

        ai_message = AIMessage(
            content=self._normalize_content(message.get("content")),
            tool_calls=tool_calls,
            invalid_tool_calls=invalid_tool_calls,
            additional_kwargs=additional_kwargs,
            usage_metadata=_build_usage_metadata(usage),
            response_metadata={
                "model": response.get("model", self.model),
                "finish_reason": choice.get("finish_reason"),
                "usage": usage,
            },
        )
        return ChatResult(
            generations=[ChatGeneration(message=ai_message)],
            llm_output={
                "token_usage": usage,
                "model_name": response.get("model", self.model),
            },
        )

    def _generate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: CallbackManagerForLLMRun | None = None,
        **kwargs: Any,
    ) -> ChatResult:
        payload = self._build_payload(messages, stop, kwargs)
        logger.debug("Calling VS Code Copilot bridge model=%s url=%s", self.model, self._endpoint_url())
        return self._parse_response(self._post_chat_completion(payload))

    async def _agenerate(
        self,
        messages: list[BaseMessage],
        stop: list[str] | None = None,
        run_manager: AsyncCallbackManagerForLLMRun | None = None,
        **kwargs: Any,
    ) -> ChatResult:
        payload = self._build_payload(messages, stop, kwargs)
        logger.debug("Calling VS Code Copilot bridge model=%s url=%s", self.model, self._endpoint_url())
        return self._parse_response(await self._apost_chat_completion(payload))

    @staticmethod
    def _format_tool(tool: Any) -> dict[str, Any] | None:
        if isinstance(tool, BaseTool):
            try:
                function = convert_to_openai_function(tool)
            except Exception:
                function = {
                    "name": tool.name,
                    "description": tool.description or "",
                    "parameters": {"type": "object", "properties": {}},
                }
            return {"type": "function", "function": function}
        if isinstance(tool, dict):
            if tool.get("type") == "function" and isinstance(tool.get("function"), dict):
                return tool
            if "name" in tool:
                return {
                    "type": "function",
                    "function": {
                        "name": tool["name"],
                        "description": tool.get("description", ""),
                        "parameters": tool.get("parameters") or tool.get("input_schema") or {"type": "object", "properties": {}},
                    },
                }
        return None

    def bind_tools(self, tools: list, **kwargs: Any) -> Any:
        formatted_tools = []
        for tool in tools:
            formatted_tool = self._format_tool(tool)
            if formatted_tool is not None:
                formatted_tools.append(formatted_tool)
        return RunnableBinding(bound=self, kwargs={"tools": formatted_tools}, **kwargs)

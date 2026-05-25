from __future__ import annotations

from typing import Any

from langchain_core.messages import HumanMessage

from deerflow.models.vscode_copilot_provider import VSCodeCopilotChatModel


def _patch_bridge_response(monkeypatch, model: VSCodeCopilotChatModel, response: dict[str, Any], captured_payload: dict[str, Any]) -> None:
    def fake_post_chat_completion(payload: dict[str, Any]) -> dict[str, Any]:
        captured_payload.update(payload)
        return response

    monkeypatch.setattr(model, "_post_chat_completion", fake_post_chat_completion)


def test_vscode_copilot_provider_builds_payload_and_parses_text(monkeypatch):
    model = VSCodeCopilotChatModel(
        model="gpt-5.4",
        base_url="http://127.0.0.1:8765",
        temperature=0.2,
        reasoning_effort="xhigh",
    )
    captured_payload: dict[str, Any] = {}
    _patch_bridge_response(
        monkeypatch,
        model,
        {
            "id": "chatcmpl-test",
            "model": "gpt-5.4",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ready"}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5},
        },
        captured_payload,
    )

    result = model._generate([HumanMessage(content="hello")])
    message = result.generations[0].message

    assert captured_payload["model"] == "gpt-5.4"
    assert captured_payload["messages"] == [{"role": "user", "content": "hello"}]
    assert captured_payload["temperature"] == 0.2
    assert captured_payload["reasoning_effort"] == "xhigh"
    assert message.content == "ready"
    assert message.usage_metadata == {"input_tokens": 3, "output_tokens": 2, "total_tokens": 5}


def test_vscode_copilot_provider_runtime_reasoning_effort_overrides_default(monkeypatch):
    model = VSCodeCopilotChatModel(model="gpt-5.4", reasoning_effort="high")
    captured_payload: dict[str, Any] = {}
    _patch_bridge_response(
        monkeypatch,
        model,
        {
            "id": "chatcmpl-test",
            "model": "gpt-5.4",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": "ready"}, "finish_reason": "stop"}],
            "usage": {},
        },
        captured_payload,
    )

    model._generate([HumanMessage(content="hello")], reasoning_effort="xhigh")

    assert captured_payload["reasoning_effort"] == "xhigh"


def test_vscode_copilot_provider_parses_tool_calls(monkeypatch):
    model = VSCodeCopilotChatModel(model="gpt-4o")
    captured_payload: dict[str, Any] = {}
    _patch_bridge_response(
        monkeypatch,
        model,
        {
            "id": "chatcmpl-test",
            "model": "gpt-4o",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "id": "call_123",
                                "type": "function",
                                "function": {"name": "lookup", "arguments": '{"query":"status"}'},
                            }
                        ],
                    },
                    "finish_reason": "tool_calls",
                }
            ],
        },
        captured_payload,
    )

    result = model._generate([HumanMessage(content="check")])
    message = result.generations[0].message

    assert message.tool_calls == [{"name": "lookup", "args": {"query": "status"}, "id": "call_123", "type": "tool_call"}]
    assert message.additional_kwargs["tool_calls"][0]["id"] == "call_123"


def test_vscode_copilot_provider_bind_tools_uses_openai_tool_shape():
    model = VSCodeCopilotChatModel()

    bound = model.bind_tools(
        [
            {
                "type": "function",
                "function": {
                    "name": "lookup",
                    "description": "Look up information",
                    "parameters": {"type": "object", "properties": {"query": {"type": "string"}}},
                },
            }
        ]
    )

    assert bound.kwargs["tools"] == [
        {
            "type": "function",
            "function": {
                "name": "lookup",
                "description": "Look up information",
                "parameters": {"type": "object", "properties": {"query": {"type": "string"}}},
            },
        }
    ]

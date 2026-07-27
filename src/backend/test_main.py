import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, Mock, patch

import httpx
from fastapi import HTTPException

import main


class InvokeRequestTests(unittest.IsolatedAsyncioTestCase):
    async def test_malformed_json_returns_422(self):
        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://test",
        ) as client:
            response = await client.post(
                "/invoke",
                content='{"message":',
                headers={"content-type": "application/json"},
            )

        self.assertEqual(response.status_code, 422)

    async def test_unexpected_fields_return_422(self):
        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://test",
        ) as client:
            response = await client.post(
                "/invoke",
                json={"message": "hello", "unexpected": True},
            )

        self.assertEqual(response.status_code, 422)


class SpaRouteTests(unittest.IsolatedAsyncioTestCase):
    async def test_spa_redirect_config_and_static_index(self):
        transport = httpx.ASGITransport(app=main.app)
        async with httpx.AsyncClient(
            transport=transport,
            base_url="http://test",
            follow_redirects=False,
        ) as client:
            redirect = await client.get("/spa")
            config = await client.get("/spa/env-config.js")
            index = await client.get("/spa/")

        self.assertEqual(redirect.status_code, 307)
        self.assertEqual(redirect.headers["location"], "/spa/")
        self.assertEqual(config.status_code, 200)
        self.assertEqual(config.headers["cache-control"], "no-store")
        self.assertIn(main.SPA_CLIENT_ID, config.text)
        self.assertIn('"AGENT_API_URL": "/invoke"', config.text)
        self.assertEqual(index.status_code, 200)
        self.assertIn("Agent ID POC", index.text)

    def test_oidc_routes_are_scoped(self):
        paths = {route.path for route in main.app.routes}

        self.assertIn(
            "/spiffe-oidc/.well-known/openid-configuration",
            paths,
        )
        self.assertIn(
            "/.well-known/openid-configuration/spiffe-oidc",
            paths,
        )
        self.assertIn("/spiffe-oidc/keys", paths)
        self.assertNotIn("/.well-known/openid-configuration", paths)
        self.assertNotIn("/keys", paths)


class AgentModeTests(unittest.TestCase):
    def test_accepts_supported_modes(self):
        self.assertEqual(main._validate_agent_mode("user_context"), "user_context")
        self.assertEqual(main._validate_agent_mode("app_only"), "app_only")

    def test_rejects_unsupported_mode(self):
        with self.assertRaisesRegex(RuntimeError, "Invalid AGENT_MODE"):
            main._validate_agent_mode("app-only")


class DownstreamScopeTests(unittest.TestCase):
    def test_parses_whitespace_delimited_scopes(self):
        self.assertEqual(
            main._parse_scopes("scope.one  scope.two\nscope.three"),
            ["scope.one", "scope.two", "scope.three"],
        )

    def test_rejects_empty_scope_configuration(self):
        with self.assertRaisesRegex(RuntimeError, "at least one scope"):
            main._parse_scopes("  \t\n")

    def test_accepts_read_only_scope_configuration(self):
        self.assertEqual(
            main._parse_read_only_scopes(
                "api://resource/MCP.User.Read.All api://resource/MCP.Group.Read.All"
            ),
            [
                "api://resource/MCP.User.Read.All",
                "api://resource/MCP.Group.Read.All",
            ],
        )

    def test_rejects_non_read_scope_configuration(self):
        with self.assertRaisesRegex(RuntimeError, "only read permissions"):
            main._parse_read_only_scopes("api://resource/MCP.User.ReadWrite.All")


class ReadinessTests(unittest.IsolatedAsyncioTestCase):
    async def test_ready_when_all_dependencies_are_available(self):
        with (
            patch.object(main, "_is_spire_socket_ready", return_value=True),
            patch.object(main, "_probe_jwks", new=AsyncMock(return_value=True)),
        ):
            response = await main.readyz()

        content = json.loads(response.body)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(content["status"], "ready")
        self.assertTrue(all(content["checks"].values()))

    async def test_not_ready_when_a_dependency_is_unavailable(self):
        with (
            patch.object(main, "_is_spire_socket_ready", return_value=True),
            patch.object(
                main,
                "_probe_jwks",
                new=AsyncMock(side_effect=[False, True]),
            ),
        ):
            response = await main.readyz()

        content = json.loads(response.body)
        self.assertEqual(response.status_code, 503)
        self.assertEqual(content["status"], "not_ready")
        self.assertFalse(content["checks"]["oidc_provider"])


class AgentRunTests(unittest.TestCase):
    def _client_with_response(self, response):
        client = Mock()
        client.responses.create.return_value = response
        return client

    def test_uses_authenticated_enterprise_mcp_tool(self):
        response = SimpleNamespace(
            output_text="The tenant has 12 users.",
            output=[
                SimpleNamespace(
                    type="mcp_call",
                    name="entra_users_list",
                    status="completed",
                )
            ],
        )
        client = self._client_with_response(response)

        with (
            patch.object(main, "_get_openai_client", return_value=client),
            patch.object(main.uuid, "uuid4", return_value="agent-request-123"),
        ):
            result = main._run_agent_sync(
                "How many users?",
                "agent-mcp-token",
                [{"role": "assistant", "content": "What would you like to know?"}],
            )

        call = client.responses.create.call_args.kwargs
        self.assertEqual(call["model"], main.AZURE_OPENAI_DEPLOYMENT)
        self.assertEqual(call["instructions"], main.AI_AGENT_SYSTEM_PROMPT)
        self.assertEqual(
            call["input"],
            [
                {"role": "assistant", "content": "What would you like to know?"},
                {"role": "user", "content": "How many users?"},
            ],
        )
        self.assertFalse(call["store"])
        self.assertEqual(call["tools"][0]["type"], "mcp")
        self.assertEqual(call["tools"][0]["server_url"], main.MCP_SERVER_URL)
        self.assertEqual(call["tools"][0]["authorization"], "agent-mcp-token")
        self.assertEqual(call["tools"][0]["require_approval"], "never")
        self.assertEqual(result["answer"], "The tenant has 12 users.")
        self.assertEqual(
            result["tool_calls"],
            [{"name": "entra_users_list", "status": "completed"}],
        )
        self.assertEqual(result["request_id"], "agent-request-123")

    def test_rejects_empty_agent_answer(self):
        client = self._client_with_response(SimpleNamespace(output_text="  ", output=[]))

        with patch.object(main, "_get_openai_client", return_value=client):
            with self.assertRaises(HTTPException) as raised:
                main._run_agent_sync("hello", "agent-mcp-token")

        self.assertEqual(raised.exception.status_code, 502)
        self.assertEqual(raised.exception.detail["message"], "AI agent returned no answer")

    def test_maps_model_timeout_to_gateway_timeout(self):
        client = Mock()
        client.responses.create.side_effect = main.APITimeoutError(
            request=httpx.Request("POST", "https://ai.example/openai/v1/responses")
        )

        with (
            patch.object(main, "_get_openai_client", return_value=client),
            patch.object(main.uuid, "uuid4", return_value="agent-request-456"),
        ):
            with self.assertRaises(HTTPException) as raised:
                main._run_agent_sync("hello", "agent-mcp-token")

        self.assertEqual(raised.exception.status_code, 504)
        self.assertEqual(raised.exception.detail["request_id"], "agent-request-456")


if __name__ == "__main__":
    unittest.main()
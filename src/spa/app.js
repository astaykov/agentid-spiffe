// Runtime configuration is served by FastAPI at /spa/env-config.js.
const ENV = window.__ENV__ || {};

const config = {
  auth: {
    clientId: ENV.SPA_CLIENT_ID,
    authority: `https://login.microsoftonline.com/${ENV.TENANT_ID}`,
    redirectUri: `${window.location.origin}/spa/`,
  },
};

const BLUEPRINT_SCOPE = ENV.BLUEPRINT_SCOPE;
const AGENT_API_URL = ENV.AGENT_API_URL || "/invoke";

const msalInstance = new msal.PublicClientApplication(config);
const chatMessages = document.getElementById("chatMessages");
const messageInput = document.getElementById("msgInput");
const sendButton = document.getElementById("sendBtn");
const status = document.getElementById("status");
const history = [];

const setStatus = (message) => {
  status.textContent = message;
};

const appendMessage = (role, content, metadata = "") => {
  const row = document.createElement("div");
  row.className = `chat-message ${role}`;

  const bubble = document.createElement("div");
  bubble.className = "chat-bubble";
  bubble.textContent = content;

  if (metadata) {
    const meta = document.createElement("span");
    meta.className = "chat-meta";
    meta.textContent = metadata;
    bubble.appendChild(meta);
  }

  row.appendChild(bubble);
  chatMessages.appendChild(row);
  chatMessages.scrollTop = chatMessages.scrollHeight;
};

const enableChat = (account) => {
  messageInput.disabled = false;
  sendButton.disabled = false;
  setStatus(`Signed in as ${account?.username || "user"}.`);
  messageInput.focus();
};

appendMessage(
  "assistant",
  "Sign in to ask read-only questions about Microsoft Entra ID.",
);

const msalReady = (async () => {
  if (!ENV.SPA_CLIENT_ID || !ENV.TENANT_ID || !BLUEPRINT_SCOPE) {
    throw new Error("Missing SPA runtime configuration.");
  }
  await msalInstance.initialize();
  const redirectResult = await msalInstance.handleRedirectPromise();
  const account = redirectResult?.account || msalInstance.getAllAccounts()[0];
  if (account) {
    msalInstance.setActiveAccount(account);
    enableChat(account);
  }
})();

msalReady.catch((e) => setStatus("Initialization failed: " + e.message));

document.getElementById("loginBtn").addEventListener("click", async () => {
  try {
    await msalReady;
    setStatus("Opening sign-in popup...");
    const result = await msalInstance.loginPopup({ scopes: [BLUEPRINT_SCOPE] });
    msalInstance.setActiveAccount(result.account);
    enableChat(result.account);
  } catch (e) {
    setStatus("Login failed: " + e.message);
  }
});

const sendMessage = async () => {
  const message = messageInput.value.trim();
  if (!message || sendButton.disabled) {
    return;
  }

  const priorHistory = history.slice(-20);
  appendMessage("user", message);
  messageInput.value = "";
  messageInput.disabled = true;
  sendButton.disabled = true;
  setStatus("Agent is working...");

  try {
    await msalReady;
    const account = msalInstance.getActiveAccount() || msalInstance.getAllAccounts()[0];
    let tokenResponse;
    try {
      tokenResponse = await msalInstance.acquireTokenSilent({
        scopes: [BLUEPRINT_SCOPE],
        account,
      });
    } catch (e) {
      tokenResponse = await msalInstance.acquireTokenPopup({ scopes: [BLUEPRINT_SCOPE] });
    }

    const resp = await fetch(AGENT_API_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${tokenResponse.accessToken}`,
      },
      body: JSON.stringify({ message, history: priorHistory }),
    });
    const data = await resp.json();
    if (!resp.ok) {
      const detail = data.detail?.message || data.detail || `HTTP ${resp.status}`;
      throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
    }

    const tools = (data.tool_calls || [])
      .map((tool) => tool.name)
      .filter(Boolean);
    const metadata = tools.length
      ? `Tools: ${tools.join(", ")} · Model: ${data.model}`
      : `Model: ${data.model}`;
    appendMessage("assistant", data.answer, metadata);
    history.push(
      { role: "user", content: message },
      { role: "assistant", content: data.answer },
    );
    setStatus("Ready.");
  } catch (e) {
    appendMessage("assistant", "The agent could not complete that request.", e.message);
    setStatus("Request failed.");
  } finally {
    messageInput.disabled = false;
    sendButton.disabled = false;
    messageInput.focus();
  }
};

sendButton.addEventListener("click", sendMessage);
messageInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    sendMessage();
  }
});

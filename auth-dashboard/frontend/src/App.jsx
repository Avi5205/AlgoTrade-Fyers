import { useState } from "react";

const API_BASE = "http://localhost:8000/api";

function App() {
  const [loginUrl, setLoginUrl] = useState("");
  const [authCode, setAuthCode] = useState("");
  const [accessToken, setAccessToken] = useState("");
  const [refreshToken, setRefreshToken] = useState("");
  const [profileResp, setProfileResp] = useState(null);
  const [status, setStatus] = useState("");

  async function generateAuthUrl() {
    try {
      setStatus("Generating login URL...");
      const res = await fetch(`${API_BASE}/auth-url`);
      if (!res.ok) {
        throw new Error(await res.text());
      }
      const data = await res.json();
      setLoginUrl(data.login_url);
      setStatus("Login URL generated. Open it in a new tab and complete FYERS login.");
    } catch (err) {
      setStatus(`Error generating login URL: ${err.message || String(err)}`);
    }
  }

  async function exchangeAuthCode() {
    try {
      if (!authCode.trim()) {
        setStatus("Please paste auth_code first.");
        return;
      }
      setStatus("Exchanging auth_code for token...");
      const res = await fetch(`${API_BASE}/exchange`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ auth_code: authCode.trim() }),
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error(text);
      }
      const data = await res.json();
      setAccessToken(data.access_token);
      setRefreshToken(data.refresh_token || "");
      setStatus("Token exchange successful. You can now save the token.");
    } catch (err) {
      setStatus(`Error exchanging auth_code: ${err.message || String(err)}`);
    }
  }

  async function saveTokenAndRestart() {
    try {
      if (!accessToken.trim()) {
        setStatus("No access_token to save. Exchange auth_code first.");
        return;
      }
      setStatus("Saving token and restarting Docker services...");
      const res = await fetch(`${API_BASE}/save-token`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          access_token: accessToken.trim(),
          restart_docker: true,
        }),
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error(text);
      }
      const data = await res.json();
      setStatus(
        data.message + (data.docker_output ? `\n${data.docker_output}` : "")
      );
    } catch (err) {
      setStatus(`Error saving token: ${err.message || String(err)}`);
    }
  }

  async function testProfile() {
    try {
      setStatus("Testing FYERS profile using current token...");
      const res = await fetch(`${API_BASE}/test-profile`);
      if (!res.ok) {
        const text = await res.text();
        throw new Error(text);
      }
      const data = await res.json();
      setProfileResp(data);
      setStatus(data.message);
    } catch (err) {
      setStatus(`Error testing profile: ${err.message || String(err)}`);
    }
  }

  return (
    <div
      style={{
        maxWidth: 900,
        margin: "0 auto",
        padding: "1.5rem",
        fontFamily: "system-ui, sans-serif",
      }}
    >
      <h1>FYERS Swing Bot – Auth Dashboard</h1>
      <p style={{ color: "#555" }}>
        Use this page to generate a login URL, exchange <code>auth_code</code>,
        save the new token to <code>credentials.env</code>, restart Docker
        services, and verify authentication.
      </p>

      {/* 1. Generate login URL */}
      <section
        style={{
          marginTop: "2rem",
          padding: "1rem",
          border: "1px solid #ddd",
          borderRadius: 8,
        }}
      >
        <h2>1. Generate FYERS Login URL</h2>
        <button onClick={generateAuthUrl}>Generate Login URL</button>
        {loginUrl && (
          <div style={{ marginTop: "1rem" }}>
            <div>Login URL:</div>
            <textarea
              readOnly
              value={loginUrl}
              style={{ width: "100%", height: 80, fontFamily: "monospace" }}
            />
            <p>
              Open this URL in a new tab, complete the FYERS login and 2FA, then
              copy the <code>auth_code</code> from the redirect URL.
            </p>
          </div>
        )}
      </section>

      {/* 2. auth_code -> token */}
      <section
        style={{
          marginTop: "2rem",
          padding: "1rem",
          border: "1px solid #ddd",
          borderRadius: 8,
        }}
      >
        <h2>2. Paste auth_code and Exchange</h2>
        <label>
          auth_code from FYERS redirect URL:
          <textarea
            value={authCode}
            onChange={(e) => setAuthCode(e.target.value)}
            style={{
              width: "100%",
              height: 80,
              fontFamily: "monospace",
              marginTop: 8,
            }}
          />
        </label>
        <div style={{ marginTop: "0.75rem" }}>
          <button onClick={exchangeAuthCode}>Exchange auth_code for token</button>
        </div>

        {accessToken && (
          <div style={{ marginTop: "1rem" }}>
            <div>Access token (will be saved to credentials.env):</div>
            <textarea
              readOnly
              value={accessToken}
              style={{ width: "100%", height: 80, fontFamily: "monospace" }}
            />
          </div>
        )}
        {refreshToken && (
          <div style={{ marginTop: "0.5rem" }}>
            <div>Refresh token (for future use if needed):</div>
            <textarea
              readOnly
              value={refreshToken}
              style={{ width: "100%", height: 60, fontFamily: "monospace" }}
            />
          </div>
        )}
      </section>

      {/* 3. Save & restart */}
      <section
        style={{
          marginTop: "2rem",
          padding: "1rem",
          border: "1px solid #ddd",
          borderRadius: 8,
        }}
      >
        <h2>3. Save Token & Restart Bot Containers</h2>
        <p>
          This will write <code>FYERS_ACCESS_TOKEN</code> into{" "}
          <code>credentials.env</code> and run{" "}
          <code>docker compose up -d fyers-swing-bot penny-trader</code> in your
          project root.
        </p>
        <button onClick={saveTokenAndRestart}>
          Save token and restart Docker services
        </button>
      </section>

      {/* 4. Test profile */}
      <section
        style={{
          marginTop: "2rem",
          padding: "1rem",
          border: "1px solid #ddd",
          borderRadius: 8,
        }}
      >
        <h2>4. Test FYERS Profile</h2>
        <p>
          This uses the token currently in <code>credentials.env</code>,
          exactly like your trading bot containers.
        </p>
        <button onClick={testProfile}>Test Profile</button>

        {profileResp && (
          <div style={{ marginTop: "1rem" }}>
            <div>
              Status:{" "}
              <strong style={{ color: profileResp.ok ? "green" : "red" }}>
                {profileResp.message}
              </strong>
            </div>
            <pre
              style={{
                marginTop: "0.5rem",
                maxHeight: 300,
                overflow: "auto",
                background: "#f7f7f7",
                padding: "0.75rem",
                fontSize: 12,
              }}
            >
              {JSON.stringify(profileResp.raw, null, 2)}
            </pre>
          </div>
        )}
      </section>

      {/* Status area */}
      <section style={{ marginTop: "2rem" }}>
        <h2>Status</h2>
        <pre
          style={{
            background: "#f0f0f0",
            padding: "0.75rem",
            minHeight: 60,
            whiteSpace: "pre-wrap",
          }}
        >
          {status || "Idle."}
        </pre>
      </section>
    </div>
  );
}

export default App;

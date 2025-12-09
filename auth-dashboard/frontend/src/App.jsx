import { useState } from "react";
import "./App.css";

const API_BASE = "http://127.0.0.1:8000";

const API_ENDPOINTS = {
  AUTH_URL: "/api/auth-url",
  EXCHANGE: "/api/exchange",
  SAVE_TOKEN: "/api/save-token",
  PROFILE: "/api/test-profile",
  RECOMMENDATIONS: "/api/recommendations",
  EXECUTED: "/api/executed",
  CLEAR_ERRORS: "/api/clear-error-executions",
  PLACE_ORDER: "/api/place-order",
  RUN_SCANNER: "/api/run-scanner",
};

async function apiCall(path, options = {}) {
  const res = await fetch(`${API_BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });
  const data = await res.json();
  if (!res.ok) {
    const detail = data?.detail ?? res.statusText;
    throw new Error(typeof detail === "string" ? detail : JSON.stringify(detail));
  }
  return data;
}

function useApiCall() {
  const [loading, setLoading] = useState(null);
  const [errorMsg, setErrorMsg] = useState("");

  const call = async (key, path, options = {}) => {
    try {
      setErrorMsg("");
      setLoading(key);
      return await apiCall(path, options);
    } catch (err) {
      setErrorMsg(err.message);
      throw err;
    } finally {
      setLoading(null);
    }
  };

  return { call, loading, errorMsg, setErrorMsg };
}

function App() {
  const { call, loading, errorMsg, setErrorMsg } = useApiCall();

  const [loginUrl, setLoginUrl] = useState("");
  const [authCode, setAuthCode] = useState("");
  const [tokenResponse, setTokenResponse] = useState(null);
  const [savedTokenInfo, setSavedTokenInfo] = useState(null);
  const [profileInfo, setProfileInfo] = useState(null);
  const [recoRows, setRecoRows] = useState([]);
  const [execRows, setExecRows] = useState([]);
  const [clearExecInfo, setClearExecInfo] = useState(null);
  const [orderForm, setOrderForm] = useState({
    fyers_symbol: "",
    side: "BUY",
    qty: 1,
  });
  const [orderResult, setOrderResult] = useState(null);
  const [scannerResult, setScannerResult] = useState(null);

  const isBusy = (key) => loading === key;
  const clearLoading = () => setLoading(null);

  const handleGenerateAuthUrl = async () => {
    try {
      setErrorMsg("");
      setTokenResponse(null);
      setSavedTokenInfo(null);
      setProfileInfo(null);
      setLoading("auth-url");
      const data = await call("auth-url", API_ENDPOINTS.AUTH_URL);
      setLoginUrl(data.login_url);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleExchangeCode = async () => {
    try {
      setErrorMsg("");
      setLoading("exchange");
      setTokenResponse(null);
      const data = await call("exchange", API_ENDPOINTS.EXCHANGE, {
        method: "POST",
        body: JSON.stringify({ auth_code: authCode }),
      });
      setTokenResponse(data);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleSaveToken = async () => {
    if (!tokenResponse?.access_token) {
      setErrorMsg("No access_token to save. Exchange code first.");
      return;
    }
    try {
      setErrorMsg("");
      setLoading("save-token");
      const data = await call("save-token", API_ENDPOINTS.SAVE_TOKEN, {
        method: "POST",
        body: JSON.stringify({
          access_token: tokenResponse.access_token,
          restart_docker: true,
        }),
      });
      setSavedTokenInfo(data);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleTestProfile = async () => {
    try {
      setErrorMsg("");
      setLoading("profile");
      const data = await call("profile", API_ENDPOINTS.PROFILE);
      setProfileInfo(data);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleLoadRecommendations = async () => {
    try {
      setErrorMsg("");
      setLoading("reco");
      const data = await call("reco", API_ENDPOINTS.RECOMMENDATIONS);
      setRecoRows(data.rows || []);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleLoadExecuted = async () => {
    try {
      setErrorMsg("");
      setLoading("exec");
      const data = await call("exec", API_ENDPOINTS.EXECUTED);
      setExecRows(data.rows || []);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleClearErrorExec = async () => {
    try {
      setErrorMsg("");
      setLoading("clear-exec");
      const data = await call("clear-exec", API_ENDPOINTS.CLEAR_ERRORS, {
        method: "POST",
      });
      setClearExecInfo(data);
      const refreshed = await call("exec", API_ENDPOINTS.EXECUTED);
      setExecRows(refreshed.rows || []);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleOrderFormChange = (field, value) => {
    setOrderForm((prev) => ({
      ...prev,
      [field]: value,
    }));
  };

  const validateOrder = (form) => {
    if (!form.fyers_symbol.trim()) return "FYERS Symbol is required";
    if (!form.qty || form.qty <= 0) return "Quantity must be positive";
    return null;
  };

  const handlePlaceOrder = async () => {
    try {
      setErrorMsg("");
      setOrderResult(null);
      setLoading("place-order");
      const payload = {
        fyers_symbol: orderForm.fyers_symbol.trim(),
        side: orderForm.side,
        qty: Number(orderForm.qty) || 0,
      };
      const data = await call("place-order", API_ENDPOINTS.PLACE_ORDER, {
        method: "POST",
        body: JSON.stringify(payload),
      });
      setOrderResult(data);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  const handleRunScanner = async () => {
    try {
      setErrorMsg("");
      setScannerResult(null);
      setLoading("scanner");
      const data = await call("scanner", API_ENDPOINTS.RUN_SCANNER, {
        method: "POST",
      });
      setScannerResult(data);
    } catch (err) {
      setErrorMsg(err.message);
    } finally {
      clearLoading();
    }
  };

  return (
    <div className="App">
      <header className="app-header">
        <h1>FYERS Auth & Control Dashboard</h1>
        <p className="subtitle">
          Simplified re-authentication, diagnostics, and manual controls for your
          fyers-swing-docker stack.
        </p>
      </header>

      {errorMsg && (
        <div className="alert alert-error">
          <strong>Error: </strong> {errorMsg}
        </div>
      )}

      {/* Row 1: Auth Flow */}
      <div className="grid">
        <section className="card">
          <h2>1. Generate Login URL</h2>
          <p>
            Uses <code>credentials.env</code> to create the FYERS login URL.
          </p>
          <button
            className="btn btn-primary"
            onClick={handleGenerateAuthUrl}
            disabled={isBusy("auth-url")}
          >
            {isBusy("auth-url") ? "Generating..." : "Generate Login URL"}
          </button>
          {loginUrl && (
            <div className="panel">
              <p>Open this URL in your browser and complete FYERS login.</p>
              <textarea
                className="mono"
                rows={3}
                readOnly
                value={loginUrl}
              />
            </div>
          )}
        </section>

        <section className="card">
          <h2>2. Paste Auth Code</h2>
          <p>
            After login, you will be redirected to your{" "}
            <code>FYERS_REDIRECT_URI</code>. Copy the <code>auth_code</code>{" "}
            query parameter and paste it here.
          </p>
          <textarea
            className="mono"
            rows={4}
            value={authCode}
            onChange={(e) => setAuthCode(e.target.value)}
            placeholder="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
          />
          <button
            className="btn btn-secondary"
            onClick={handleExchangeCode}
            disabled={isBusy("exchange")}
          >
            {isBusy("exchange") ? "Exchanging..." : "Exchange auth_code"}
          </button>
          {tokenResponse && (
            <div className="panel panel-success">
              <p>
                <strong>Exchange result:</strong>
              </p>
              <textarea
                className="mono"
                rows={6}
                readOnly
                value={JSON.stringify(tokenResponse, null, 2)}
              />
            </div>
          )}
        </section>
      </div>

      {/* Row 2: Save token + Test profile */}
      <div className="grid">
        <section className="card">
          <h2>3. Save Token & Restart Docker</h2>
          <p>
            Writes <code>FYERS_ACCESS_TOKEN</code> into{" "}
            <code>credentials.env</code> and restarts{" "}
            <code>fyers-swing-bot</code> & <code>penny-trader</code>.
          </p>
          <button
            className="btn btn-success"
            onClick={handleSaveToken}
            disabled={isBusy("save-token") || !tokenResponse?.access_token}
          >
            {isBusy("save-token")
              ? "Saving & restarting..."
              : "Save Token & Restart Services"}
          </button>
          {savedTokenInfo && (
            <div className="panel panel-success">
              <p>{savedTokenInfo.message}</p>
              {savedTokenInfo.docker_output && (
                <textarea
                  className="mono"
                  rows={5}
                  readOnly
                  value={savedTokenInfo.docker_output}
                />
              )}
            </div>
          )}
        </section>

        <section className="card">
          <h2>4. Test FYERS Profile</h2>
          <p>
            Uses the token currently in <code>credentials.env</code>, exactly
            like your trading bot containers.
          </p>
          <button
            className="btn btn-secondary"
            onClick={handleTestProfile}
            disabled={isBusy("profile")}
          >
            {isBusy("profile") ? "Checking..." : "Test Profile"}
          </button>
          {profileInfo && (
            <div
              className={
                "panel " +
                (profileInfo.ok ? "panel-success" : "panel-warning")
              }
            >
              <p>
                <strong>Status:</strong> {profileInfo.message}
              </p>
              <textarea
                className="mono"
                rows={6}
                readOnly
                value={JSON.stringify(profileInfo.raw, null, 2)}
              />
            </div>
          )}
        </section>
      </div>

      {/* Row 3: Recommendations & Executed */}
      <div className="grid">
        <section className="card">
          <h2>5. View Recommendations</h2>
          <p>
            Shows <code>data/penny_recommendations.csv</code> as parsed by
            pandas.
          </p>
          <button
            className="btn btn-secondary"
            onClick={handleLoadRecommendations}
            disabled={isBusy("reco")}
          >
            {isBusy("reco") ? "Loading..." : "Load Recommendations"}
          </button>
          {recoRows && recoRows.length > 0 && (
            <div className="table-wrapper">
              <table className="data-table">
                <thead>
                  <tr>
                    {Object.keys(recoRows[0]).map((col) => (
                      <th key={col}>{col}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {recoRows.map((row, idx) => (
                    <tr key={idx}>
                      {Object.keys(recoRows[0]).map((col) => (
                        <td key={col}>{String(row[col] ?? "")}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <section className="card">
          <h2>6. View & Clean Executed Trades</h2>
          <p>
            Reads <code>data/penny_trades_executed.csv</code>. You can clear
            failed/error rows to keep the log clean.
          </p>
          <div className="button-row">
            <button
              className="btn btn-secondary"
              onClick={handleLoadExecuted}
              disabled={isBusy("exec")}
            >
              {isBusy("exec") ? "Loading..." : "Load Executed Trades"}
            </button>
            <button
              className="btn btn-danger"
              onClick={handleClearErrorExec}
              disabled={isBusy("clear-exec")}
            >
              {isBusy("clear-exec") ? "Clearing..." : "Clear Error Executions"}
            </button>
          </div>

          {clearExecInfo && (
            <div className="panel panel-warning">
              <p>{clearExecInfo.message}</p>
            </div>
          )}

          {execRows && execRows.length > 0 && (
            <div className="table-wrapper">
              <table className="data-table">
                <thead>
                  <tr>
                    {Object.keys(execRows[0]).map((col) => (
                      <th key={col}>{col}</th>
                    ))}
                  </tr>
                </thead>
                <tbody>
                  {execRows.map((row, idx) => (
                    <tr key={idx}>
                      {Object.keys(execRows[0]).map((col) => (
                        <td key={col}>{String(row[col] ?? "")}</td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>

      {/* Row 4: Manual order + Run scanner */}
      <div className="grid">
        <section className="card">
          <h2>7. Quick Manual Market Order</h2>
          <p>
            Places a simple CNC market order via FYERS using the dashboard
            token.
          </p>
          <div className="form-grid">
            <label>
              FYERS Symbol
              <input
                type="text"
                value={orderForm.fyers_symbol}
                onChange={(e) =>
                  handleOrderFormChange("fyers_symbol", e.target.value)
                }
                placeholder="NSE:SYNCOMF-EQ"
              />
            </label>
            <label>
              Side
              <select
                value={orderForm.side}
                onChange={(e) =>
                  handleOrderFormChange("side", e.target.value)
                }
              >
                <option value="BUY">BUY</option>
                <option value="SELL">SELL</option>
              </select>
            </label>
            <label>
              Quantity
              <input
                type="number"
                min="1"
                value={orderForm.qty}
                onChange={(e) =>
                  handleOrderFormChange("qty", e.target.value)
                }
              />
            </label>
          </div>
          <button
            className="btn btn-primary"
            onClick={handlePlaceOrder}
            disabled={isBusy("place-order")}
          >
            {isBusy("place-order") ? "Placing..." : "Place Order"}
          </button>

          {orderResult && (
            <div
              className={
                "panel " +
                (orderResult.ok ? "panel-success" : "panel-warning")
              }
            >
              <p>
                <strong>{orderResult.ok ? "Order OK" : "Order Error"}</strong>:{" "}
                {orderResult.message}
              </p>
              <textarea
                className="mono"
                rows={6}
                readOnly
                value={JSON.stringify(orderResult.raw, null, 2)}
              />
            </div>
          )}
        </section>

        <section className="card">
          <h2>8. Run Scanner Now</h2>
          <p>
            Runs <code>scripts/penny_scanner.py</code> inside{" "}
            <code>fyers-swing-bot</code>, using the same environment as your
            live engine.
          </p>
          <button
            className="btn btn-secondary"
            onClick={handleRunScanner}
            disabled={isBusy("scanner")}
          >
            {isBusy("scanner") ? "Running..." : "Run Scanner Now"}
          </button>

          {scannerResult && (
            <div
              className={
                "panel " +
                (scannerResult.ok ? "panel-success" : "panel-warning")
              }
              style={{ marginTop: "0.9rem" }}
            >
              <p>
                <strong>Status:</strong> {scannerResult.message} (exit code{" "}
                {scannerResult.return_code})
              </p>

              {scannerResult.stdout && (
                <>
                  <p>
                    <strong>stdout</strong>
                  </p>
                  <textarea
                    className="mono"
                    rows={8}
                    readOnly
                    value={scannerResult.stdout}
                  />
                </>
              )}

              {scannerResult.stderr && (
                <>
                  <p>
                    <strong>stderr</strong>
                  </p>
                  <textarea
                    className="mono"
                    rows={6}
                    readOnly
                    value={scannerResult.stderr}
                  />
                </>
              )}
            </div>
          )}
        </section>
      </div>
    </div>
  );
}

export default App;

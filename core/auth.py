import os
from fyers_apiv3 import fyersModel

CLIENT_ID = os.getenv("FYERS_CLIENT_ID")
SECRET_KEY = os.getenv("FYERS_SECRET_KEY")
REDIRECT_URI = os.getenv("FYERS_REDIRECT_URI")
ACCESS_TOKEN = os.getenv("FYERS_ACCESS_TOKEN")


def get_fyers_client() -> fyersModel.FyersModel:
    if not CLIENT_ID or not SECRET_KEY or not ACCESS_TOKEN:
        raise RuntimeError("FYERS credentials or access token not set in environment variables.")

    # Fyers v3 docs: token should be the access_token string, client_id is app_id (e.g., F08DGQJ3AM-100)
    fyers = fyersModel.FyersModel(
        client_id=CLIENT_ID,
        token=ACCESS_TOKEN,
        is_async=False,
        log_path="logs",
    )
    return fyers

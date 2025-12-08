import os
from fyers_apiv3 import fyersModel

CLIENT_ID = os.getenv("FYERS_CLIENT_ID")
SECRET_KEY = os.getenv("FYERS_SECRET_KEY")
REDIRECT_URI = os.getenv("FYERS_REDIRECT_URI")


def main():
    if not CLIENT_ID or not SECRET_KEY or not REDIRECT_URI:
        raise RuntimeError(
            "Set FYERS_CLIENT_ID, FYERS_SECRET_KEY, FYERS_REDIRECT_URI in config/credentials.env"
        )

    grant_type = "authorization_code"
    response_type = "code"
    state = "sample_state"

    # This is the official v3 way: use SessionModel from fyersModel
    appSession = fyersModel.SessionModel(
        client_id=CLIENT_ID,
        redirect_uri=REDIRECT_URI,
        response_type=response_type,
        state=state,
        secret_key=SECRET_KEY,
        grant_type=grant_type,
    )

    # Step 1: generate login URL
    login_url = appSession.generate_authcode()
    print("\nOpen this URL in your browser, login to FYERS, and approve the app:")
    print(login_url)
    print("\nAfter login, you will be redirected to your redirect URL.")
    print("Copy the value of 'auth_code' from that URL.\n")

    auth_code = input("Enter auth_code: ").strip()

    # Step 2: exchange auth_code -> access_token
    appSession.set_token(auth_code)
    response = appSession.generate_token()
    print("\nRaw token response:")
    print(response)

    try:
        access_token = response["access_token"]
    except Exception as e:
        print("\nERROR extracting access_token from response:")
        print(e)
        return

    print(
        "\n\n=== ACCESS TOKEN (copy & paste into config/credentials.env as FYERS_ACCESS_TOKEN) ===\n"
    )
    print(access_token)


if __name__ == "__main__":
    main()

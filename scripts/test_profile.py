import os
import sys
from datetime import datetime

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(PROJECT_ROOT)

from core.auth import get_fyers_client


def main():
    print("Running profile/funds test at", datetime.now().isoformat())
    fyers = get_fyers_client()

    print("\n=== get_profile() ===")
    resp_profile = fyers.get_profile()
    print(resp_profile)

    print("\n=== funds() ===")
    resp_funds = fyers.funds()
    print(resp_funds)


if __name__ == "__main__":
    main()

import os
import sys
from datetime import datetime

from apscheduler.schedulers.blocking import BlockingScheduler

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(PROJECT_ROOT)

from scripts.scan_profitability_yf import scan_universe_yf, REPORT_PATH  # reuse existing logic


def run_scan():
    print("\n================================================")
    print("Running daily NIFTY50 swing scan (Yahoo) at", datetime.now().isoformat())
    print("================================================\n")
    scan_universe_yf()
    print("\n[Daily scan completed at", datetime.now().isoformat(), "]")
    print("Latest report file:", REPORT_PATH)
    print("================================================\n")


def main():
    scheduler = BlockingScheduler(timezone="Asia/Kolkata")

    # Run every trading day at 18:00 IST (you can adjust)
    scheduler.add_job(
        run_scan,
        trigger="cron",
        day_of_week="mon-fri",
        hour=18,
        minute=0,
        id="daily_swing_scan_yf",
        replace_existing=True,
    )

    print("Starting daily swing scan scheduler (Yahoo-based)...")
    print("Schedule: Mon–Fri at 18:00 Asia/Kolkata\n")
    run_scan()  # optional: run immediately on startup once
    scheduler.start()


if __name__ == "__main__":
    main()

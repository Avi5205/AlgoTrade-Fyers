from apscheduler.schedulers.blocking import BlockingScheduler

from jobs.daily_scan import run_daily_scan
from jobs.preopen_execute import execute_preopen_orders


def main():
    scheduler = BlockingScheduler(timezone="Asia/Kolkata")
    scheduler.add_job(run_daily_scan, "cron", day_of_week="mon-fri", hour=15, minute=40)
    scheduler.add_job(execute_preopen_orders, "cron", day_of_week="mon-fri", hour=9, minute=10)

    print("Starting scheduler...")
    scheduler.start()


if __name__ == "__main__":
    main()

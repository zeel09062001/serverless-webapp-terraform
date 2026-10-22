"""Unit tests for the monthly report's logic: dates, money and email content."""
import pytest


@pytest.mark.parametrize(
    "scheduled_time, expected_month",
    [
        ("2026-11-01T08:00:00Z", "2026-10"),  # normal: 1 Nov -> October
        ("2026-10-31T18:00:00Z", "2026-10"),  # 08:00 on 1 Nov in UTC+14 is still 31 Oct in UTC
        ("2027-01-01T02:30:00Z", "2026-12"),  # across a year boundary
    ],
)
def test_month_comes_from_the_scheduled_time(report, scheduled_time, expected_month):
    assert report.month_to_report({"scheduledTime": scheduled_time}) == expected_month


def test_a_manual_run_can_choose_the_month(report):
    assert report.month_to_report({"month": "2026-07"}) == "2026-07"


def test_a_manual_run_rejects_a_bad_month(report):
    with pytest.raises(ValueError):
        report.month_to_report({"month": "July"})


@pytest.mark.parametrize(
    "cents, text",
    [(0, "$0.00"), (5, "$0.05"), (1250, "$12.50"), (123456789, "$1,234,567.89")],
)
def test_money_is_formatted_without_floating_point(report, cents, text):
    assert report.money(cents) == text


def test_summary_totals_and_sorts_categories(report):
    expenses = [
        {"category": "food", "amountCents": 500, "merchant": "Cafe", "date": "2026-10-01"},
        {"category": "travel", "amountCents": 3000, "merchant": "Train", "date": "2026-10-02"},
        {"category": "food", "amountCents": 700, "merchant": "Bakery", "date": "2026-10-03"},
    ]
    summary = report.summarize(expenses)

    assert summary["total"] == 4200
    assert summary["categories"] == [("travel", 3000), ("food", 1200)]  # biggest first
    assert summary["biggest"]["merchant"] == "Train"


def test_user_text_is_escaped_in_the_html_email(report):
    expenses = [{
        "category": "food",
        "amountCents": 100,
        "merchant": "<a href='https://evil.example'>Verify your account</a>",
        "date": "2026-10-01",
    }]
    _, _, html_body = report.build_email("2026-10", report.summarize(expenses))

    assert "<a href" not in html_body         
    assert "&lt;a href=" in html_body         